import Foundation

/// Defers preference-driven mutations until SwiftUI has finished its current
/// view update and keeps only the newest value for each geometry channel.
@MainActor
final class SwiftUIPreferenceUpdateCoalescer {
    enum Key: Hashable {
        case tabWidths
        case tabPositions
        case bracketFrames
        case scrollViewport
        case tabBarSize
        case tabBarFrame
        case renderedTabCount
    }

    private var generations: [Key: UInt64] = [:]

    func schedule(_ key: Key, mutation: @escaping @MainActor () -> Void) {
        let generation = (generations[key] ?? 0) &+ 1
        generations[key] = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generations[key] == generation else { return }
            self.generations.removeValue(forKey: key)
            mutation()
        }
    }
}
