import Foundation
import XCTest
@testable import DiveID

/// Size evidence (Docs/HybridRankingContract.md, "Size"): a maximum-only record is
/// compatible up to the existing tolerance above its maximum and conflicts beyond it;
/// no minimum or typical range is invented; a width is never compared as a length.
final class SizeEvidenceTests: XCTestCase {
    private func profile(minimum: Double?, maximum: Double?, measurements: [String: Any]?) async throws -> LocalSpeciesProfile {
        let repository = BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: .experimentalDevelopment)
        let base = try await repository.loadPack(id: .caribbean).profiles[0]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        object["minimumSizeCentimeters"] = minimum ?? NSNull()
        object["maximumSizeCentimeters"] = maximum ?? NSNull()
        object["measurements"] = measurements ?? NSNull()
        object["appearanceVariants"] = []
        return try JSONDecoder().decode(LocalSpeciesProfile.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func sizeClue(_ centimeters: Int, _ profile: LocalSpeciesProfile) async throws -> String {
        let observation = await LocalObservationParser().parse("A \(centimeters) cm fish on a coral reef.")
        XCTAssertEqual(observation.approximateSizeCentimeters, Double(centimeters))
        let ranked = try await LocalSpeciesRanker().rank(observation: observation, profiles: [profile])
        let result = try XCTUnwrap(ranked.first, "a size never removes the candidate on its own here")
        if result.matchedClues.contains("compatible size") { return "compatible" }
        if result.conflictingClues.contains("described size") { return "conflict" }
        return "none"
    }

    func testMaximumOnlyIsCompatibleUpToTheToleranceAndConflictsAbove() async throws {
        let maxOnly = try await profile(minimum: nil, maximum: 20, measurements: [
            "typicalObservedMinimumCentimeters": NSNull(), "typicalObservedMaximumCentimeters": NSNull(),
            "maximumRecordedCentimeters": 20, "type": "totalLength"])
        let small = try await sizeClue(2, maxOnly)
        let near = try await sizeClue(25, maxOnly)
        let edge = try await sizeClue(30, maxOnly)
        let large = try await sizeClue(40, maxOnly)
        XCTAssertEqual(small, "compatible", "no minimum is invented")
        XCTAssertEqual(near, "compatible")
        XCTAssertEqual(edge, "compatible", "1.5 × maximum is the existing tolerance")
        XCTAssertEqual(large, "conflict")
        let legacy = try await profile(minimum: nil, maximum: 20, measurements: nil)
        let legacyLarge = try await sizeClue(40, legacy)
        XCTAssertEqual(legacyLarge, "conflict", "a legacy maximum-only record behaves the same")
    }

    func testMinimumAndMaximumKeepTheExistingRange() async throws {
        let ranged = try await profile(minimum: 10, maximum: 20, measurements: [
            "typicalObservedMinimumCentimeters": 10, "typicalObservedMaximumCentimeters": 20,
            "maximumRecordedCentimeters": 25, "type": "totalLength"])
        let tiny = try await sizeClue(4, ranged)
        let mid = try await sizeClue(15, ranged)
        let large = try await sizeClue(35, ranged)
        XCTAssertEqual(tiny, "conflict", "below half the minimum")
        XCTAssertEqual(mid, "compatible")
        XCTAssertEqual(large, "conflict", "above 1.5 × the typical maximum")
    }

    func testWidthMeasurementsAreNeverComparedAsLengths() async throws {
        for type in ["discWidth", "carapaceWidth"] {
            let wide = try await profile(minimum: nil, maximum: 100, measurements: [
                "typicalObservedMinimumCentimeters": NSNull(), "typicalObservedMaximumCentimeters": NSNull(),
                "maximumRecordedCentimeters": 100, "type": type])
            let huge = try await sizeClue(300, wide)
            let small = try await sizeClue(20, wide)
            XCTAssertEqual(huge, "none", "\(type): a described length is not compared with a width")
            XCTAssertEqual(small, "none", "\(type)")
        }
    }

    func testNoSizeIsNeutral() async throws {
        let unsized = try await profile(minimum: nil, maximum: nil, measurements: nil)
        let clue = try await sizeClue(40, unsized)
        XCTAssertEqual(clue, "none")
    }
}
