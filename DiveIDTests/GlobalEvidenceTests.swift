import Foundation
import XCTest
@testable import DiveID

/// The Global pack keeps the identification evidence its source supports
/// (Fixtures/GlobalEvidence.v1.json, shared with Tools/FishBaseIntake/test_global_evidence.py).
final class GlobalEvidenceTests: XCTestCase {
    private struct Expectation: Decodable { let variant: String?; let field: String; let includes: String?; let excludes: String?; let source: String }
    private struct Species: Decodable { let name: String; let speciesID: UUID; let expect: [Expectation] }
    private struct Fixture: Decodable { let species: [Species] }

    private func values(_ profile: LocalSpeciesProfile, _ e: Expectation) -> [String]? {
        if let stage = e.variant {
            let variants = profile.appearanceVariants.filter { $0.lifeStage.rawValue == stage }
            guard !variants.isEmpty else { return nil }
            return variants.flatMap { v -> [String] in
                switch e.field {
                case "colors": v.colors
                case "markings": v.markings
                case "distinguishingFeatures": v.distinguishingFeatures
                default: []
                }
            }
        }
        switch e.field {
        case "colors": return profile.colors
        case "markings": return profile.markings
        case "habitats": return profile.habitats
        case "behaviors": return profile.behaviors
        case "distinguishingFeatures": return profile.distinguishingFeatures
        case "mouthAndHeadShape": return profile.mouthAndHeadShape
        case "finAndSpineClues": return profile.finAndSpineClues
        case "tailShape": return profile.tailShape.map { [$0] } ?? []
        default: XCTFail("unknown field \(e.field)"); return []
        }
    }

    func testSourceSupportedEvidenceIsPresentInGlobalRecords() async throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: TestResources.fixture(named: "GlobalEvidence.v1")))
        let repository = BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: .experimentalDevelopment)
        let profiles = Dictionary(uniqueKeysWithValues: try await repository.loadPack(id: .global).profiles.map { ($0.id, $0) })
        for species in fixture.species {
            let profile = try XCTUnwrap(profiles[species.speciesID], "\(species.name) missing from Global")
            for e in species.expect {
                let label = "\(species.name): \(e.variant ?? "main").\(e.field) (\(e.source))"
                guard let found = values(profile, e) else { XCTFail("\(label): no \(e.variant!) variant"); continue }
                if let wanted = e.includes { XCTAssertTrue(found.contains { $0.lowercased().contains(wanted) }, "\(label) lacks '\(wanted)'; has \(found)") }
                if let unwanted = e.excludes { XCTAssertFalse(found.contains { $0.lowercased() == unwanted }, "\(label) wrongly has '\(unwanted)'") }
            }
        }
    }
}
