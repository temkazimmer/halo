import CoreGraphics
import Foundation

public struct ShapePreset: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var style: BubbleStyle

    public init(id: UUID = UUID(), name: String, style: BubbleStyle) {
        self.id = id
        self.name = name
        self.style = style
    }
}

/// The user's saved shapes, in the order they chose.
///
/// Codable rather than tied to UserDefaults so the ordering and round-tripping
/// can be tested without touching app storage.
public struct ShapePresetLibrary: Codable, Equatable, Sendable {
    public private(set) var presets: [ShapePreset]

    public init(presets: [ShapePreset] = []) {
        self.presets = presets
    }

    /// A starting set, so the preset row is never an empty shelf on first run.
    public static func builtIn() -> ShapePresetLibrary {
        ShapePresetLibrary(presets: [
            ShapePreset(name: "Classic", style: BubbleStyle(shape: .circle)),
            ShapePreset(
                name: "Soft Square",
                style: BubbleStyle(
                    shape: .squircle(exponent: 4),
                    border: BorderStyle(width: 3, color: .white))),
            ShapePreset(
                name: "Spotlight",
                style: BubbleStyle(
                    shape: .circle,
                    feather: 4,
                    shadow: ShadowStyle(radius: 30, opacity: 0.45))),
            ShapePreset(
                name: "Hex",
                style: BubbleStyle(shape: .polygon(sides: 6, rounding: 0.12))),
            ShapePreset(
                name: "Blob",
                style: BubbleStyle(shape: .blob(lobes: 4, amplitude: 0.14, phase: 0.6, seed: 21))),
        ])
    }

    public mutating func add(_ preset: ShapePreset) {
        presets.append(preset)
    }

    public mutating func remove(id: ShapePreset.ID) {
        presets.removeAll { $0.id == id }
    }

    public mutating func rename(id: ShapePreset.ID, to name: String) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index].name = name
    }

    /// Reorders by drag. `destination` is the index *before* removal, matching
    /// SwiftUI's `onMove` contract.
    ///
    /// Written out rather than using SwiftUI's `move(fromOffsets:toOffset:)`,
    /// which lives in SwiftUI and would drag a UI framework into the model.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { presets[$0] }
        // Remove from the back so the earlier indices stay valid.
        for index in source.sorted(by: >) { presets.remove(at: index) }
        // Every element removed from before the destination shifts it left.
        let insertionPoint = destination - source.count(where: { $0 < destination })
        presets.insert(contentsOf: moving, at: min(max(insertionPoint, 0), presets.count))
    }

    /// The preset bound to ⌘1…⌘9, or `nil` past the ninth.
    public func preset(forShortcutIndex index: Int) -> ShapePreset? {
        guard index >= 0, index < min(9, presets.count) else { return nil }
        return presets[index]
    }

    // MARK: - Persistence

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decoded(from data: Data) -> ShapePresetLibrary? {
        try? JSONDecoder().decode(ShapePresetLibrary.self, from: data)
    }
}
