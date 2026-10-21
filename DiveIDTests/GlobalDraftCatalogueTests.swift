import Foundation
import XCTest
@testable import DiveID

/// The generated FishBase/SeaLifeBase drafts must load with the app's own decoder and
/// pass the same validation as a bundled pack, together with the kept Caribbean records.
final class GlobalDraftCatalogueTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func decode(_ url: URL) throws -> [LocalSpeciesProfile] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([LocalSpeciesProfile].self, from: Data(contentsOf: url))
    }

    func testDraftsDecodeAndValidateAsOneGlobalCatalogue() throws {
        let drafts = repository.appendingPathComponent("Data/GlobalMarine/FishBase/Drafts")
        let batches = try FileManager.default.contentsOfDirectory(at: drafts, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("batch-") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(batches.isEmpty)
        var profiles: [LocalSpeciesProfile] = []
        for batch in batches {
            let records = try decode(batch)
            XCTAssertLessThanOrEqual(records.count, 250, batch.lastPathComponent)
            profiles += records
        }
        let caribbean = try decode(repository.appendingPathComponent("DiveID/Resources/IdentificationPacks/Caribbean/Creatures.json"))
        XCTAssertNoThrow(try BundleMarineSpeciesCatalogRepository.validate(profiles + caribbean.map(withoutBundledImage)))
        XCTAssertTrue(profiles.allSatisfy { $0.review?.status == .draft && $0.bundledImage == nil })
        XCTAssertTrue(profiles.allSatisfy { $0.dataSources.first?.sourceLicense == "CC BY-NC 4.0" })
    }

    /// Image files live in the app bundle, which SwiftPM tests don't load; images aren't under test here.
    private func withoutBundledImage(_ profile: LocalSpeciesProfile) -> LocalSpeciesProfile {
        var copy = profile
        copy.bundledImage = nil
        return copy
    }
}
