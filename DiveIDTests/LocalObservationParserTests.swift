import XCTest
@testable import DiveID

final class LocalObservationParserMeasurementTests: XCTestCase {
    private let parser = LocalObservationParser()

    func testExplicitContextAssignsOneRolePerMeasurementOccurrence() async {
        await assertMeasurement("around 10 m deep", size: nil, depth: 10)
        await assertMeasurement("about 10 cm long", size: 10, depth: nil)
        await assertMeasurement("🐠 près du récif, around 10 m deep", size: nil, depth: 10)
    }

    func testDistinctOccurrencesCanSupplySizeAndDepth() async {
        await assertMeasurement("a 10 cm fish at 10 m deep", size: 10, depth: 10)
        await assertMeasurement("10 m long at 10 m depth", size: 1_000, depth: 10)
        await assertMeasurement("at 10 m depth, a 10 m long fish", size: 1_000, depth: 10)
        await assertMeasurement("at 10 m deep, a 10 cm long fish", size: 10, depth: 10)
    }

    func testExistingApproximateMeasurementsAndConversionsRemainSupported() async {
        await assertMeasurement("around 60 feet deep", size: nil, depth: 18.288)
        await assertMeasurement("roughly 12 inches long", size: 30.48, depth: nil)
        await assertMeasurement("length about 2 meters", size: 200, depth: nil)
        await assertMeasurement("a fish at a depth of 20 meters", size: nil, depth: 20)
    }

    private func assertMeasurement(
        _ description: String,
        size: Double?,
        depth: Double?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let observation = await parser.parse(description)
        if let size {
            XCTAssertEqual(observation.approximateSizeCentimeters ?? -1, size, accuracy: 0.001, file: file, line: line)
        } else {
            XCTAssertNil(observation.approximateSizeCentimeters, file: file, line: line)
        }
        if let depth {
            XCTAssertEqual(observation.approximateDepthMeters ?? -1, depth, accuracy: 0.001, file: file, line: line)
        } else {
            XCTAssertNil(observation.approximateDepthMeters, file: file, line: line)
        }
    }
}
