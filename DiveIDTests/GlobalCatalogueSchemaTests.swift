import Foundation
import XCTest
@testable import DiveID

final class GlobalCatalogueSchemaTests: XCTestCase {
    func testEveryFishBaseAndSeaLifeBaseLengthBasisDecodes() throws {
        let types = ["totalLength", "standardLength", "forkLength", "discWidth", "discLength",
                     "carapaceLength", "carapaceWidth", "shellLength", "mantleLength", "bodyLength"]
        for type in types {
            let json = #"{"typicalObservedMinimumCentimeters": null, "typicalObservedMaximumCentimeters": null, "maximumRecordedCentimeters": 12.5, "type": "\#(type)"}"#
            let measurements = try JSONDecoder().decode(SpeciesMeasurements.self, from: Data(json.utf8))
            XCTAssertEqual(measurements.type.rawValue, type)
        }
    }

    func testUnknownLengthBasisIsRejected() {
        let json = #"{"maximumRecordedCentimeters": 12.5, "type": "notGiven"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(SpeciesMeasurements.self, from: Data(json.utf8)))
    }

    func testInvertebrateAnimalGroupsAreRecognizedInDescriptions() async {
        let cases: [(String, String)] = [
            ("A black sea cucumber on the sand", "sea cucumber"),
            ("Two sea cucumbers on rubble", "sea cucumber"),
            ("A spiny purple urchin in a crevice", "sea urchin"),
            ("A big jellyfish drifting near the surface", "jellyfish"),
            ("A red worm in a tube on the reef", "worm"),
            ("An orange sea squirt on the wall", "sea squirt"),
            ("A horseshoe crab on the sand", "horseshoe crab")
        ]
        for (text, category) in cases {
            let observation = await LocalObservationParser().parse(text)
            XCTAssertTrue(observation.categories.contains(category), "\(text) → \(observation.categories)")
        }
    }

    func testJellyfishIsNotParsedAsAFish() async {
        let observation = await LocalObservationParser().parse("A big jellyfish drifting near the surface")
        XCTAssertFalse(observation.categories.contains("fish"))
    }
}
