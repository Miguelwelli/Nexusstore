import Foundation
@testable import NexusStoreCore

/// Loads the seed JSON straight from the source tree on Linux (SWIFT_PACKAGE resources are not
/// visible from the test module without `Bundle.module` of the library; this keeps the check honest
/// and simple).
enum SeedCatalogBridge {
    static func load() -> [Game] {
        let candidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // NexusStoreCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("NexusStore/Resources/Seed/seed-catalog.json")
        guard let data = try? Data(contentsOf: candidate) else { return [] }
        return SeedCatalog.decode(data)
    }
}
