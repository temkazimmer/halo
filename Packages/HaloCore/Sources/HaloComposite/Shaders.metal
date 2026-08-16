#include <metal_stdlib>
using namespace metal;

// Kept in step with `CompositorUniforms` in Swift by hand. The two definitions
// must move together — `CompositorUniformsTests` asserts the Swift side's size
// and alignment so a drift shows up as a test failure rather than corrupt video.
struct Uniforms {
    float2 bubbleCentre;     // normalised, 0...1 in output space
    float2 bubbleRadius;     // normalised half-extent, x and y
    float  cornerAntialias;  // minimum AA width in normalised units
    float  feather;          // extra softness beyond analytic AA
    float  cameraAspect;     // camera texture aspect ratio
    float  zoom;
    float2 cameraOffset;     // pan within the mask
    uint   mirrorCamera;     // 0 or 1
    uint   cameraIsYCbCr;    // 0 = BGRA, 1 = biplanar YCbCr
    uint   cameraIsFullRange;// 0 = video range, 1 = full range
    uint   hasCamera;        // 0 when no frame has arrived yet
    uint   hasScreen;        // 0 for the floating preview, which is transparent
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
    return select(c / 12.92,
                  pow((c + 0.055) / 1.055, 3.0),
                  c > 0.04045);
}

static inline float3 linearToSrgb(float3 c) {
    return select(c * 12.92,
                  1.055 * pow(c, 1.0 / 2.4) - 0.055,
                  c > 0.0031308);
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
    // Rec.709 luma coefficients.
    return float3(
        ycbcr.x + 1.5748 * ycbcr.z,
        ycbcr.x - 0.1873 * ycbcr.y - 0.4681 * ycbcr.z,
        ycbcr.x + 1.8556 * ycbcr.y);
}

// MARK: - Shape

/// Circle in normalised local space. Phase 5 replaces this with the full SDF
/// library; the antialiasing around it is already the final approach.
static inline float sdCircle(float2 p) {
    return length(p) - 1.0;
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

    // The floating preview has no screen layer: the real desktop shows through
    // the transparent panel behind it. Everything else — mask, antialiasing,
    // colour conversion — runs identically, which is what makes the preview and
    // the recording agree rather than merely resemble each other.
    float3 screen = u.hasScreen != 0
        ? screenTexture.sample(linearSampler, in.uv).rgb
        : float3(0.0);

    if (u.hasCamera == 0) {
        return u.hasScreen != 0 ? float4(screen, 1.0) : float4(0.0);
    }

    // Position within the bubble, normalised so the SDF works on a unit circle.
    float2 local = (in.uv - u.bubbleCentre) / u.bubbleRadius;

    float d  = sdCircle(local);
    // Screen-space derivative, floored: a heavily minified quad aliases badly on
    // pure derivative AA.
    float aa = max(fwidth(d), u.cornerAntialias);
    float alpha = 1.0 - smoothstep(-aa, aa, d);
    if (u.feather > 0.0) {
        alpha *= smoothstep(0.0, u.feather, -d + u.feather);
    }

    if (alpha <= 0.0) {
        return u.hasScreen != 0 ? float4(screen, 1.0) : float4(0.0);
    }

    // Map the bubble's local space onto the camera texture, preserving aspect so
    // faces are never stretched, and cropping to fill.
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
        // bgra8Unorm already reorders components in hardware, so this samples as
        // plain RGBA — swizzling here would swap red and blue.
        camera = cameraLuma.sample(linearSampler, cameraUV).rgb;
    }

    // Both sides into linear P3 before they meet.
    float3 cameraLinear = rec709ToDisplayP3(srgbToLinear(saturate(camera)));
    float3 screenLinear = srgbToLinear(screen);

    if (u.hasScreen == 0) {
        // Premultiplied, always: masking and *then* premultiplying is what keeps
        // the rim free of the dark or bright fringe an unpremultiplied blend
        // against an alpha ramp produces.
        return float4(linearToSrgb(cameraLinear) * alpha, alpha);
    }

    float3 blended = mix(screenLinear, cameraLinear, alpha);
    return float4(linearToSrgb(blended), 1.0);
}
