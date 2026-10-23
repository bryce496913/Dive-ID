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

    /// Records whose source lacks a required field are left empty (never invented) and
    /// carry a `missing_required` risk flag. Every other draft must load and validate.
    func testDraftsDecodeAndValidateAsOneGlobalCatalogue() throws {
        let staging = repository.appendingPathComponent("Data/GlobalMarine/FishBase")
        let drafts = staging.appendingPathComponent("Drafts")
        let batches = try FileManager.default.contentsOfDirectory(at: drafts, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("batch-") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(batches.isEmpty)
        var profiles: [LocalSpeciesProfile] = []
        for batch in batches {
            let records = try decode(batch)
            XCTAssertLessThanOrEqual(records.count, 250, batch.lastPathComponent)
            profiles += records
        }
        let risk = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: staging.appendingPathComponent("RiskReport.json"))) as? [String: Any])
        let records = try XCTUnwrap(risk["records"] as? [String: [String: Any]])
        let incomplete = Set(records.filter { ($0.value["flags"] as? [String] ?? []).contains { $0.hasPrefix("missing_required") } }.keys)
        let complete = profiles.filter { !incomplete.contains($0.id.uuidString.lowercased()) }
        XCTAssertEqual(profiles.count - complete.count, incomplete.count, "only flagged records are set aside")
        XCTAssertLessThan(incomplete.count, 10)
        // The drafts carry the 8 Caribbean species themselves (built from FishBase, last in
        // the build order), so they validate as one catalogue without the regional pack.
        let caribbean = try decode(repository.appendingPathComponent("DiveID/Resources/IdentificationPacks/Caribbean/Creatures.json"))
        XCTAssertTrue(Set(caribbean.map(\.id)).isSubset(of: Set(complete.map(\.id))), "every Caribbean species is in Global")
        XCTAssertEqual(Array(complete.suffix(caribbean.count)).map(\.id).sorted { $0.uuidString < $1.uuidString },
                       caribbean.map(\.id).sorted { $0.uuidString < $1.uuidString }, "Caribbean records come last")
        XCTAssertNoThrow(try BundleMarineSpeciesCatalogRepository.validate(complete))
        XCTAssertTrue(profiles.allSatisfy { $0.review?.status == .draft && $0.bundledImage == nil })
        XCTAssertTrue(profiles.allSatisfy { $0.dataSources.first?.sourceLicense == "CC BY-NC 4.0" && !($0.dataSources.first?.reviewedFields.isEmpty ?? true) })
    }
}
