#include <metal_stdlib>
using namespace metal;

constant float PI = 3.14159265358979323846;

// Kept in step with `CompositorUniforms` in Swift by hand. The two definitions
// must move together — `CompositorTests` asserts the Swift side's size,
// alignment and stride so a drift shows up as a test failure rather than as
// corrupt video. Fields are ordered widest-first to keep both layouts obvious.
struct Uniforms {
    float4 borderColor;      // linear-ready sRGB, alpha premultiplies nothing here
    float4 shadowColor;

    float2 bubbleCentre;     // normalised, 0...1 in output space
    float2 bubbleRadius;     // normalised half-extent
    float2 cameraOffset;     // pan within the mask
    float2 shadowOffset;     // normalised

    float cornerAntialias;   // minimum AA width, normalised
    float feather;           // fine softness beyond analytic AA, normalised
    float edgeBlur;          // wide soft falloff, normalised
    float cameraAspect;
    float zoom;
    float rotation;          // radians
    float aspect;            // squash, 0.5...2
    float shapeA;            // exponent / cornerRadius / sides / points / lobes
    float shapeB;            // rounding / innerRatio / amplitude
    float shapeC;            // rounding (star) / phase
    float shapeD;            // blob seed, as an angle
    float borderWidth;       // normalised; 0 disables
    float shadowRadius;      // normalised; 0 disables
    float shadowOpacity;
    float time;              // seconds; unused for now, reserved for animation

    uint shapeKind;
    uint mirrorCamera;
    uint cameraIsYCbCr;
    uint cameraIsFullRange;
    uint hasCamera;
    uint hasScreen;          // 0 for the floating preview, which is transparent
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Fullscreen triangle. Cheaper than a quad and needs no vertex buffer: the
// vertex id alone determines the position.
vertex VertexOut fullscreenVertex(uint vertexID [[vertex_id]]) {
    float2 uv = float2((vertexID << 1) & 2, vertexID & 2);
    VertexOut out;
    out.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    out.uv = uv;
    return out;
}

// MARK: - Colour
//
// The composite happens in linear light. An alpha ramp blended in gamma-encoded
// sRGB produces a visibly darker edge than the same ramp in linear, and the
// difference lands exactly on the bubble's rim where it is most obvious.

static inline float3 srgbToLinear(float3 c) {
    // 2.4, not 3.0: the sRGB transfer function's exponent. Getting this wrong
    // darkens the camera and only shows up as a round-trip error, which is what
    // the pass-through test measures.
    return select(c / 12.92, pow((c + 0.055) / 1.055, 2.4), c > 0.04045);
}

static inline float3 linearToSrgb(float3 c) {
    return select(c * 12.92, 1.055 * pow(c, 1.0 / 2.4) - 0.055, c > 0.0031308);
}

// Rec.709 primaries into Display P3, both linear. Screen frames arrive as P3;
// camera frames are tagged 709. Blending them without this leaves the webcam
// visibly oversaturated against the screen.
static inline float3 rec709ToDisplayP3(float3 c) {
    const float3x3 m = float3x3(
        float3(0.822462, 0.033194, 0.017083),
        float3(0.177537, 0.966806, 0.072397),
        float3(0.000000, 0.000000, 0.910520));
    return m * c;
}

static inline float3 ycbcrToRGB(float y, float2 cbcr, bool fullRange) {
    float3 ycbcr = float3(y, cbcr - float2(0.5, 0.5));
    if (!fullRange) {
        // Video range packs luma into 16..235 and chroma into 16..240.
        ycbcr.x = (ycbcr.x - 16.0 / 255.0) * (255.0 / 219.0);
        ycbcr.yz = ycbcr.yz * (255.0 / 224.0);
    }
    return float3(
        ycbcr.x + 1.5748 * ycbcr.z,
        ycbcr.x - 0.1873 * ycbcr.y - 0.4681 * ycbcr.z,
        ycbcr.x + 1.8556 * ycbcr.y);
}

/// Premultiplied "over". `dst` carries premultiplied colour throughout.
static inline void over(thread float3 &dstColor, thread float &dstAlpha,
                        float3 srcColor, float srcAlpha) {
    dstColor = srcColor * srcAlpha + dstColor * (1.0 - srcAlpha);
    dstAlpha = srcAlpha + dstAlpha * (1.0 - srcAlpha);
}

// MARK: - Signed distance functions
//
// All evaluated in normalised local space where the shape's extent is 1.
// Negative inside, positive outside.

static inline float2 rotate2(float2 p, float angle) {
    float s = sin(angle);
    float c = cos(angle);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

static inline float sdCircle(float2 p) {
    return length(p) - 1.0;
}

/// Superellipse. n = 2 is a circle, n ~ 4 matches Apple's continuous corners,
/// n = 12 is nearly a square.
static inline float sdSquircle(float2 p, float n) {
    n = max(n, 2.0);
    float2 a = pow(abs(p), n);
    return pow(a.x + a.y, 1.0 / n) - 1.0;
}

static inline float sdRoundedRect(float2 p, float radius) {
    radius = clamp(radius, 0.0, 1.0);
    float2 extent = float2(1.0) - radius;
    float2 q = abs(p) - extent;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

/// Regular n-gon with circumradius 1: fold into one sector, then measure against
/// that sector's edge.
static inline float sdRegularPolygon(float2 p, float sides) {
    sides = max(sides, 3.0);
    float segment = 2.0 * PI / sides;
    float angle = atan2(p.y, p.x);
    // The + 4*PI keeps fmod's argument positive for any input angle.
    float a = fmod(angle + 4.0 * PI + segment * 0.5, segment) - segment * 0.5;
    return length(p) * cos(a) - cos(PI / sides);
}

/// Star with outer radius 1. Folds into a half-sector so only one edge — the
/// line from an outer point to its neighbouring inner point — needs measuring.
static inline float sdStar(float2 p, float points, float innerRatio) {
    points = max(points, 3.0);
    innerRatio = clamp(innerRatio, 0.05, 0.95);

    float segment = PI / points;
    float angle = atan2(p.y, p.x);
    // Shift by one half-sector so an outer point lands at a = 0.
    float a = abs(fmod(angle + segment + 4.0 * PI, 2.0 * segment) - segment);

    float2 q = float2(cos(a), sin(a)) * length(p);
    float2 outer = float2(1.0, 0.0);
    float2 inner = float2(cos(segment), sin(segment)) * innerRatio;

    float2 edge = inner - outer;
    float2 rel = q - outer;
    float h = clamp(dot(rel, edge) / dot(edge, edge), 0.0, 1.0);
    float distance = length(rel - edge * h);

    // Cross product decides which side of the edge we are on.
    float side = edge.x * rel.y - edge.y * rel.x;
    return distance * (side > 0.0 ? -1.0 : 1.0);
}

/// Radial wobble. Two decorrelated harmonics rather than one, so the result
/// reads as organic instead of as a flower.
static inline float sdBlob(float2 p, float lobes, float amplitude,
                           float phase, float seed) {
    float angle = atan2(p.y, p.x);
    float wobble =
        0.62 * sin(lobes * angle + phase) +
        0.38 * sin((lobes + 1.0) * angle * 1.31 - phase * 0.7 + seed);
    return length(p) - (1.0 + amplitude * wobble);
}

/// Rounds a shape without growing it.
///
/// Plain `d - r` rounds the corners but dilates the whole outline by `r`, so
/// dragging the rounding slider would inflate the bubble as a side effect.
/// Shrinking by the same amount first keeps the outer extent fixed, which is
/// what the control implies.
static inline float rounded(float d, float scale, float radius) {
    return d * scale - radius;
}

static inline float shapeDistance(float2 p, constant Uniforms &u) {
    switch (u.shapeKind) {
        case 1: return sdSquircle(p, u.shapeA);
        case 2: return sdRoundedRect(p, u.shapeA);
        case 3: {
            float r = clamp(u.shapeB, 0.0, 0.9);
            float s = 1.0 - r;
            return rounded(sdRegularPolygon(p / s, u.shapeA), s, r);
        }
        case 4: {
            float r = clamp(u.shapeC, 0.0, 0.9);
            float s = 1.0 - r;
            return rounded(sdStar(p / s, u.shapeA, u.shapeB), s, r);
        }
        case 5: return sdBlob(p, u.shapeA, u.shapeB, u.shapeC, u.shapeD);
        default: return sdCircle(p);
    }
}

/// Output space into the shape's own space: rotate first, then squash, so
/// rotating a squashed shape behaves the way dragging the controls implies.
static inline float2 toLocal(float2 uv, constant Uniforms &u) {
    float2 p = (uv - u.bubbleCentre) / u.bubbleRadius;
    p = rotate2(p, -u.rotation);
    p.x /= max(u.aspect, 0.01);
    return p;
}

// MARK: - Composite

fragment float4 compositeFragment(
    VertexOut in [[stage_in]],
    texture2d<float> screenTexture [[texture(0)]],
    texture2d<float> cameraLuma    [[texture(1)]],
    texture2d<float> cameraChroma  [[texture(2)]],
    constant Uniforms &u           [[buffer(0)]])
{
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);

    bool onScreen = u.hasScreen != 0;

    // The floating preview has no screen layer: the real desktop shows through
    // the transparent panel behind it. Everything else — mask, antialiasing,
    // colour conversion — runs identically, which is what makes the preview and
    // the recording agree rather than merely resemble each other.
    float3 color = onScreen
        ? srgbToLinear(screenTexture.sample(linearSampler, in.uv).rgb)
        : float3(0.0);
    float alpha = onScreen ? 1.0 : 0.0;

    if (u.hasCamera == 0) {
        return onScreen ? float4(linearToSrgb(color), 1.0) : float4(0.0);
    }

    float2 local = toLocal(in.uv, u);
    float d = shapeDistance(local, u);
    // Screen-space derivative, floored: a heavily minified quad aliases badly on
    // pure derivative AA.
    float aa = max(fwidth(d), u.cornerAntialias);

    // Shadow first, so everything else sits on top of it.
    if (u.shadowRadius > 0.0 && u.shadowOpacity > 0.0) {
        float shadowDistance = shapeDistance(toLocal(in.uv - u.shadowOffset, u), u);
        float shadowAlpha =
            (1.0 - smoothstep(0.0, u.shadowRadius, shadowDistance)) * u.shadowOpacity;
        over(color, alpha, srgbToLinear(u.shadowColor.rgb), shadowAlpha * u.shadowColor.a);
    }

    // Softness widens the transition band itself. Multiplying a second ramp on
    // top does almost nothing, because the analytic AA has already driven alpha
    // to zero everywhere that ramp would act — which is why raising feather used
    // to have no visible effect.
    float softness = max(aa, u.feather + u.edgeBlur);
    float maskAlpha = 1.0 - smoothstep(-softness, softness, d);

    if (maskAlpha > 0.0) {
        // Map the bubble's local space onto the camera texture, preserving aspect
        // so faces are never stretched, and cropping to fill.
        float2 cameraUV = local / u.zoom;
        if (u.cameraAspect > 1.0) {
            cameraUV.x /= u.cameraAspect;
        } else {
            cameraUV.y *= u.cameraAspect;
        }
        if (u.mirrorCamera != 0) { cameraUV.x = -cameraUV.x; }
        cameraUV = cameraUV * 0.5 + 0.5 + u.cameraOffset;

        float3 camera;
        if (u.cameraIsYCbCr != 0) {
            float  y    = cameraLuma.sample(linearSampler, cameraUV).r;
            float2 cbcr = cameraChroma.sample(linearSampler, cameraUV).rg;
            camera = ycbcrToRGB(y, cbcr, u.cameraIsFullRange != 0);
        } else {
            // bgra8Unorm already reorders components in hardware, so this samples
            // as plain RGBA — swizzling here would swap red and blue.
            camera = cameraLuma.sample(linearSampler, cameraUV).rgb;
        }
        over(color, alpha, rec709ToDisplayP3(srgbToLinear(saturate(camera))), maskAlpha);
    }

    // Border reuses the same distance field: |d| - width/2 is a ring for free,
    // with no second geometry and no second shape definition to keep in sync.
    if (u.borderWidth > 0.0) {
        float ring = abs(d) - u.borderWidth * 0.5;
        float borderAlpha = (1.0 - smoothstep(-aa, aa, ring)) * u.borderColor.a;
        over(color, alpha, srgbToLinear(u.borderColor.rgb), borderAlpha);
    }

    if (onScreen) {
        return float4(linearToSrgb(color), 1.0);
    }

    // Premultiplied throughout, so unpremultiply for the gamma conversion and
    // premultiply again. Encoding premultiplied colour directly would darken the
    // rim exactly where the ramp is.
    float safeAlpha = max(alpha, 1e-5);
    return float4(linearToSrgb(color / safeAlpha) * alpha, alpha);
}
