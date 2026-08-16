import HaloShapes
import SwiftUI

/// A drag-anywhere-on-the-row slider with the value editable in place.
///
/// ⌥-click resets to the default, and shift-drag is a fine adjustment — the two
/// gestures anyone who lives in a parameter panel reaches for without thinking.
struct ParameterSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    let defaultValue: Double

    @State private var isEditing = false
    @State private var draft = ""

    init(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String,
        defaultValue: Double
    ) {
        self.title = title
        self._value = value
        self.range = range
        self.format = format
        self.defaultValue = defaultValue
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.callout)
                .frame(width: 96, alignment: .leading)

            Slider(value: $value, in: range)
                .controlSize(.small)

            if isEditing {
                TextField("", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospacedDigit())
                    .frame(width: 62)
                    .onSubmit(commit)
            } else {
                Text(String(format: format, value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .trailing)
                    .contentShape(.rect)
                    .onTapGesture {
                        draft = String(format: "%g", value)
                        isEditing = true
                    }
            }
        }
        .contentShape(.rect)
        // ⌥-click anywhere on the row resets it.
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.option) { value = defaultValue }
        }
    }

    private func commit() {
        if let parsed = Double(draft) {
            value = min(range.upperBound, max(range.lowerBound, parsed))
        }
        isEditing = false
    }
}

/// Whole-number parameters — sides, points, lobes — where a slider would let you
/// land between two valid values.
struct IntegerStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    init(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) {
        self.title = title
        self._value = value
        self.range = range
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.callout)
                .frame(width: 96, alignment: .leading)
            Stepper(value: $value, in: range) {
                Text("\(value)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Thumbnail outlines

struct RegularPolygonOutline: SwiftUI.Shape {
    let sides: Int

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        for index in 0..<max(sides, 3) {
            // Start at the top so the shape reads the way people draw it.
            let angle = -.pi / 2 + 2 * .pi * Double(index) / Double(sides)
            let point = CGPoint(
                x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}

struct StarOutline: SwiftUI.Shape {
    let points: Int
    let innerRatio: Double

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        for index in 0..<(max(points, 3) * 2) {
            let isOuter = index.isMultiple(of: 2)
            let r = radius * (isOuter ? 1 : innerRatio)
            let angle = -.pi / 2 + .pi * Double(index) / Double(points)
            let point = CGPoint(x: centre.x + cos(angle) * r, y: centre.y + sin(angle) * r)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}

struct BlobOutline: SwiftUI.Shape {
    let lobes: Int
    let amplitude: Double

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        let steps = 90
        for step in 0...steps {
            let angle = 2 * .pi * Double(step) / Double(steps)
            let r = radius * (1 + amplitude * sin(Double(lobes) * angle))
            let point = CGPoint(x: centre.x + cos(angle) * r, y: centre.y + sin(angle) * r)
            step == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Colour bridging

extension Color {
    init(_ color: BubbleColor) {
        self.init(
            .sRGB, red: color.red, green: color.green, blue: color.blue,
            opacity: color.alpha)
    }

    /// Resolves through `NSColor` because SwiftUI's `Color` exposes no
    /// components directly.
    var bubbleColor: BubbleColor {
        let resolved = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return BubbleColor(
            red: Double(resolved.redComponent),
            green: Double(resolved.greenComponent),
            blue: Double(resolved.blueComponent),
            alpha: Double(resolved.alphaComponent))
    }
}
