import HaloShapes
import SwiftUI

/// The parameter surface for the bubble's shape.
///
/// Everything here applies live to the floating bubble, including during a
/// recording. Only the selected shape's own parameters are shown, so the panel
/// stays as small as the shape is simple.
struct ShapeInspectorView: View {
    @Environment(RecorderModel.self) private var recorder

    var body: some View {
        @Bindable var recorder = recorder

        VStack(alignment: .leading, spacing: 16) {
            Text("Shape")
                .font(.title3.weight(.semibold))

            ShapePickerRow()
            PresetRow()

            Divider()

            // Only the parameters that belong to the current shape.
            shapeParameters

            Divider()

            ParameterSlider(
                "Size", value: $recorder.style.size, range: 120...520,
                format: "%.0f pt", defaultValue: 220)
            ParameterSlider(
                "Aspect", value: $recorder.style.aspect, range: 0.5...2,
                format: "%.2f", defaultValue: 1)
            ParameterSlider(
                "Rotation", value: $recorder.style.rotation, range: 0...(.pi * 2),
                format: "%.2f rad", defaultValue: 0)
            ParameterSlider(
                "Zoom", value: $recorder.style.zoom, range: 1...3,
                format: "%.2f×", defaultValue: 1)
            ParameterSlider(
                "Edge Blur", value: $recorder.style.edgeBlur, range: 0...1,
                format: "%.0f%%", defaultValue: 0, displayScale: 100)
            ParameterSlider(
                "Feather", value: $recorder.style.feather,
                range: 0...BubbleStyle.maximumFeather,
                format: "%.0f px", defaultValue: 0.5)

            Divider()

            EdgeDecorations()

            Toggle("Mirror the recording", isOn: $recorder.style.mirrorOutput)
                .font(.callout)
            Text("The preview always mirrors, because that is what you expect to see. Viewers expect text behind you to read correctly, so the recording does not.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .animation(.easeOut(duration: 0.18), value: recorder.style.shape.kindIndex)
    }

    @ViewBuilder
    private var shapeParameters: some View {
        @Bindable var recorder = recorder

        switch recorder.style.shape {
        case .circle:
            Text("A circle has no parameters of its own.")
                .font(.footnote)
                .foregroundStyle(.secondary)

        case .squircle(let exponent):
            ParameterSlider(
                "Squareness",
                value: Binding(
                    get: { exponent },
                    set: { recorder.style.shape = .squircle(exponent: $0) }),
                range: 2...12, format: "%.1f", defaultValue: 4)
            Text("2 is a circle, 4 matches Apple's continuous corners, 12 is nearly a square.")
                .font(.footnote)
                .foregroundStyle(.secondary)

        case .roundedRect(let cornerRadius):
            ParameterSlider(
                "Corner Radius",
                value: Binding(
                    get: { cornerRadius },
                    set: { recorder.style.shape = .roundedRect(cornerRadius: $0) }),
                range: 0...1, format: "%.2f", defaultValue: 0.35)

        case .polygon(let sides, let rounding):
            IntegerStepper(
                "Sides",
                value: Binding(
                    get: { sides },
                    set: { recorder.style.shape = .polygon(sides: $0, rounding: rounding) }),
                range: 3...12)
            ParameterSlider(
                "Rounding",
                value: Binding(
                    get: { rounding },
                    set: { recorder.style.shape = .polygon(sides: sides, rounding: $0) }),
                range: 0...0.5, format: "%.2f", defaultValue: 0.1)

        case .star(let points, let innerRatio, let rounding):
            IntegerStepper(
                "Points",
                value: Binding(
                    get: { points },
                    set: {
                        recorder.style.shape = .star(
                            points: $0, innerRatio: innerRatio, rounding: rounding)
                    }),
                range: 3...12)
            ParameterSlider(
                "Inner Radius",
                value: Binding(
                    get: { innerRatio },
                    set: {
                        recorder.style.shape = .star(
                            points: points, innerRatio: $0, rounding: rounding)
                    }),
                range: 0.15...0.9, format: "%.2f", defaultValue: 0.45)
            ParameterSlider(
                "Rounding",
                value: Binding(
                    get: { rounding },
                    set: {
                        recorder.style.shape = .star(
                            points: points, innerRatio: innerRatio, rounding: $0)
                    }),
                range: 0...0.5, format: "%.2f", defaultValue: 0.06)

        case .blob(let lobes, let amplitude, let phase, let seed):
            IntegerStepper(
                "Lobes",
                value: Binding(
                    get: { lobes },
                    set: {
                        recorder.style.shape = .blob(
                            lobes: $0, amplitude: amplitude, phase: phase, seed: seed)
                    }),
                range: 2...12)
            ParameterSlider(
                "Amplitude",
                value: Binding(
                    get: { amplitude },
                    set: {
                        recorder.style.shape = .blob(
                            lobes: lobes, amplitude: $0, phase: phase, seed: seed)
                    }),
                range: 0...0.4, format: "%.2f", defaultValue: 0.12)
            ParameterSlider(
                "Phase",
                value: Binding(
                    get: { phase },
                    set: {
                        recorder.style.shape = .blob(
                            lobes: lobes, amplitude: amplitude, phase: $0, seed: seed)
                    }),
                range: 0...(.pi * 2), format: "%.2f", defaultValue: 0)
            Button("Reseed") {
                recorder.style.shape = .blob(
                    lobes: lobes, amplitude: amplitude, phase: phase,
                    seed: UInt32.random(in: 0..<10_000))
            }
            .controlSize(.small)
        }
    }
}

/// A row of live thumbnails, each rendering the *current* camera frame in that
/// shape rather than a static icon.
private struct ShapePickerRow: View {
    @Environment(RecorderModel.self) private var recorder

    var body: some View {
        HStack(spacing: 8) {
            ForEach(BubbleShape.allKinds, id: \.kindIndex) { candidate in
                let isSelected = recorder.style.shape.kindIndex == candidate.kindIndex
                Button {
                    recorder.style.shape = candidate
                } label: {
                    ShapeThumbnail(shape: candidate, isSelected: isSelected)
                }
                .buttonStyle(.plain)
                .help(candidate.name)
            }
        }
    }
}

/// SwiftUI outline of each shape, matching the SDFs closely enough to pick by.
///
/// Deliberately not the Metal path: rendering six live camera previews at 60fps
/// to choose between them would cost more than the bubble itself.
private struct ShapeThumbnail: View {
    let shape: BubbleShape
    let isSelected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(.quaternary))
            outline
                .fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 22, height: 22)
        }
        .frame(width: 42, height: 38)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
        }
    }

    /// `AnyShape` rather than an opaque type: `@ViewBuilder` composes Views, and
    /// a switch over six different `Shape` types has no single concrete result.
    private var outline: AnyShape {
        switch shape {
        case .circle: AnyShape(Circle())
        case .squircle: AnyShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        case .roundedRect: AnyShape(RoundedRectangle(cornerRadius: 5))
        case .polygon: AnyShape(RegularPolygonOutline(sides: 6))
        case .star: AnyShape(StarOutline(points: 5, innerRatio: 0.45))
        case .blob: AnyShape(BlobOutline(lobes: 4, amplitude: 0.14))
        }
    }
}

private struct PresetRow: View {
    @Environment(RecorderModel.self) private var recorder
    @State private var isNaming = false
    @State private var draftName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(recorder.presets.presets.enumerated()), id: \.element.id) {
                        index, preset in
                        Button(preset.name) { recorder.applyPreset(preset) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .keyboardShortcut(shortcut(for: index), modifiers: .command)
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    recorder.removePreset(id: preset.id)
                                }
                            }
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.never)

            Button("Save Current…") {
                draftName = "Preset \(recorder.presets.presets.count + 1)"
                isNaming = true
            }
            .controlSize(.small)
            .popover(isPresented: $isNaming) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Name", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    HStack {
                        Spacer()
                        Button("Save") {
                            recorder.savePreset(named: draftName)
                            isNaming = false
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(12)
            }
        }
    }

    /// ⌘1…⌘9 apply the first nine presets.
    private func shortcut(for index: Int) -> KeyEquivalent {
        guard index < 9 else { return .clear }
        return KeyEquivalent(Character("\(index + 1)"))
    }
}

private struct EdgeDecorations: View {
    @Environment(RecorderModel.self) private var recorder

    var body: some View {
        @Bindable var recorder = recorder

        VStack(alignment: .leading, spacing: 10) {
            Toggle("Border", isOn: Binding(
                get: { recorder.style.border != nil },
                set: { recorder.style.border = $0 ? BorderStyle() : nil }))
                .font(.callout)

            if let border = recorder.style.border {
                ParameterSlider(
                    "Width",
                    value: Binding(
                        get: { border.width },
                        set: { recorder.style.border?.width = $0 }),
                    range: 0.5...20, format: "%.1f pt", defaultValue: 3)
                ColorPicker("Colour", selection: Binding(
                    get: { Color(border.color) },
                    set: { recorder.style.border?.color = $0.bubbleColor }))
                    .font(.callout)
            }

            Toggle("Shadow", isOn: Binding(
                get: { recorder.style.shadow != nil },
                set: { recorder.style.shadow = $0 ? ShadowStyle() : nil }))
                .font(.callout)

            if let shadow = recorder.style.shadow {
                ParameterSlider(
                    "Radius",
                    value: Binding(
                        get: { shadow.radius },
                        set: { recorder.style.shadow?.radius = $0 }),
                    range: 0...60, format: "%.0f pt", defaultValue: 24)
                ParameterSlider(
                    "Opacity",
                    value: Binding(
                        get: { shadow.opacity },
                        set: { recorder.style.shadow?.opacity = $0 }),
                    range: 0...1, format: "%.2f", defaultValue: 0.35)
            }
        }
    }
}
