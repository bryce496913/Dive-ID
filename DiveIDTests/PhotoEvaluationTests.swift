import XCTest
@testable import DiveID
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Photo identification against held-out photos (Data/PhotoEvaluation), through the real
/// service path, with the gates in Data/Evaluation/PhotoProtocol.v1.json. Opt-in, like the
/// Global evaluation:
///
///     DIVEID_PHOTO_EVAL_REPORT=Reports/PhotoEvaluation.json swift test --filter PhotoEvaluationTests
///
/// DIVEID_PHOTO_EVAL_SPLIT=development runs the development split instead: no gates, plus the
/// abstain-threshold sweep the threshold is set from. The held-out split runs only when its
/// manifest matches the hash frozen in Data/PhotoEvaluation/Freeze.json.
/// DIVEID_PHOTO_EVAL_CANDIDATE=bioclip|dinov2 (with DIVEID_PHOTO_CANDIDATES, and optionally
/// DIVEID_PHOTO_EVAL_VARIANT=photos+text) evaluates a candidate model instead of the built-in
/// matcher (Docs/PhotoModelCandidates.md).
/// DIVEID_PHOTO_EVAL_COLOUR=1 applies the experimental underwater colour correction to every
/// photo first, as the Internal toggle does in the app.
final class PhotoEvaluationTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    struct Photo: Decodable {
        let speciesID: UUID?
        let scientificName: String
        let group: String
        let covered: Bool
        let expected: String
        let photoID: String
        let underwater: Bool?
        let sha256: String?
    }

    struct Manifest: Decodable { let split: String; let photos: [Photo] }

    struct GateProtocol: Decodable {
        let status: String
        let minimumRates: [String: Double]
        let minimumSamples: [String: Int]
    }

    /// One photo's outcome.
    struct Outcome: Codable, Equatable {
        let photoID: String
        let expected: String
        let group: String
        let covered: Bool
        let underwater: Bool?
        /// The expected species' rank among the results shown, if shown.
        let rank: Int?
        let abstained: Bool
        let compliant: Bool
        /// Best normalized photo similarity, for the threshold sweep.
        let topSimilarity: Double
        /// The expected species' rank among the recognizer's raw candidates (before abstaining).
        let rawRank: Int?
    }

    // MARK: Metrics and gates (always tested)

    struct Bucket: Codable, Equatable {
        var cases = 0, top1 = 0, top3 = 0, top10 = 0, abstained = 0, compliant = 0
        mutating func add(_ o: Outcome) {
            cases += 1
            if let rank = o.rank { top1 += rank <= 1 ? 1 : 0; top3 += rank <= 3 ? 1 : 0; top10 += rank <= 10 ? 1 : 0 }
            abstained += o.abstained ? 1 : 0
            compliant += o.compliant ? 1 : 0
        }
        func rate(_ hits: Int) -> Double? { cases == 0 ? nil : Double(hits) / Double(cases) }
        var summary: [String: Any] {
            ["cases": cases, "top1": rate(top1) as Any, "top3": rate(top3) as Any, "top10": rate(top10) as Any,
             "abstainRate": rate(abstained) as Any, "confidenceCompliant": rate(compliant) as Any]
        }
    }

    static func buckets(_ outcomes: [Outcome]) -> [String: Bucket] {
        var out: [String: Bucket] = [:]
        for o in outcomes {
            var keys: [String]
            if o.expected == "noMatch" {
                keys = ["noMatch"]
            } else {
                keys = [o.covered ? "covered" : "uncovered", "\(o.covered ? "covered" : "uncovered")/group/\(o.group)"]
                if o.covered { keys.append("covered/underwater/\(o.underwater.map { $0 ? "yes" : "no" } ?? "unknown")") }
            }
            keys.append("all")
            for key in keys { out[key, default: Bucket()].add(o) }
        }
        return out
    }

    /// Every gate's result; a failing or unevaluated gate is a failure.
    static func gates(_ buckets: [String: Bucket], _ rules: GateProtocol) -> [(name: String, passed: Bool, detail: String)] {
        let covered = buckets["covered"] ?? Bucket(), noMatch = buckets["noMatch"] ?? Bucket(), all = buckets["all"] ?? Bucket()
        func gate(_ name: String, _ bucket: Bucket, _ hits: Int, minimum: Int) -> (String, Bool, String) {
            let floor = rules.minimumRates[name] ?? 1
            guard bucket.cases >= minimum, bucket.cases > 0 else {
                return (name, false, "not evaluated: \(bucket.cases) cases, \(minimum) needed")
            }
            let rate = Double(hits) / Double(bucket.cases)
            return (name, rate >= floor, "\(hits)/\(bucket.cases) = \(String(format: "%.3f", rate)), floor \(floor)")
        }
        let coveredMinimum = rules.minimumSamples["covered"] ?? 30, noMatchMinimum = rules.minimumSamples["noMatch"] ?? 10
        return [
            gate("coveredTop1", covered, covered.top1, minimum: coveredMinimum),
            gate("coveredTop3", covered, covered.top3, minimum: coveredMinimum),
            gate("coveredTop10", covered, covered.top10, minimum: coveredMinimum),
            gate("noMatchCorrect", noMatch, noMatch.abstained, minimum: noMatchMinimum),
            gate("confidenceCompliant", all, all.compliant, minimum: 1),
        ]
    }

    /// Accuracy against abstention as the threshold rises, from the recognizer's raw output.
    static func sweep(_ outcomes: [Outcome], thresholds: [Double] = stride(from: 0.5, through: 0.99, by: 0.01).map { ($0 * 100).rounded() / 100 }) -> [[String: Any]] {
        thresholds.map { t in
            let covered = outcomes.filter { $0.expected == "species" && $0.covered }
            let noMatch = outcomes.filter { $0.expected == "noMatch" }
            func rate(_ cases: [Outcome], _ hit: (Outcome) -> Bool) -> Double? { cases.isEmpty ? nil : Double(cases.filter(hit).count) / Double(cases.count) }
            let answered = { (o: Outcome) in o.topSimilarity >= t }
            return ["threshold": t,
                    "coveredAbstainRate": rate(covered) { !answered($0) } as Any,
                    "coveredTop1": rate(covered) { answered($0) && ($0.rawRank ?? .max) <= 1 } as Any,
                    "coveredTop3": rate(covered) { answered($0) && ($0.rawRank ?? .max) <= 3 } as Any,
                    "coveredTop10": rate(covered) { answered($0) && ($0.rawRank ?? .max) <= 10 } as Any,
                    "noMatchCorrect": rate(noMatch) { !answered($0) } as Any]
        }
    }

    /// The threshold rule: the smallest threshold at which development no-match photos meet the floor.
    static func chosenThreshold(_ sweep: [[String: Any]], noMatchFloor: Double) -> Double? {
        sweep.first { ($0["noMatchCorrect"] as? Double ?? 0) >= noMatchFloor }?["threshold"] as? Double
    }

    func testMetricsGatesAndSweepOnFixedOutcomes() {
        func o(_ expected: String, covered: Bool = true, rank: Int?, abstained: Bool = false, compliant: Bool = true, top: Double = 0.8, raw: Int? = nil) -> Outcome {
            Outcome(photoID: UUID().uuidString, expected: expected, group: "fish", covered: covered, underwater: nil, rank: rank,
                    abstained: abstained, compliant: compliant, topSimilarity: top, rawRank: raw ?? rank)
        }
        let outcomes = [o("species", rank: 1), o("species", rank: 3), o("species", rank: 12), o("species", rank: nil, abstained: true, top: 0.6, raw: 2),
                        o("species", covered: false, rank: nil), o("noMatch", rank: nil, abstained: true, top: 0.7), o("noMatch", rank: nil, top: 0.9)]
        let b = Self.buckets(outcomes)
        XCTAssertEqual(b["covered"], Bucket(cases: 4, top1: 1, top3: 2, top10: 2, abstained: 1, compliant: 4))
        XCTAssertEqual(b["uncovered"]?.cases, 1)
        XCTAssertEqual(b["covered/underwater/unknown"]?.cases, 4)
        XCTAssertEqual(b["noMatch"]?.abstained, 1)

        let rules = GateProtocol(status: "test", minimumRates: ["coveredTop1": 0.25, "coveredTop3": 0.5, "coveredTop10": 0.5, "noMatchCorrect": 1, "confidenceCompliant": 1],
                                 minimumSamples: ["covered": 4, "noMatch": 2])
        let results = Self.gates(b, rules)
        XCTAssertEqual(results.filter { !$0.passed }.map(\.name), ["noMatchCorrect"], "a failing gate fails")
        let small = Self.gates(b, GateProtocol(status: "test", minimumRates: rules.minimumRates, minimumSamples: ["covered": 30, "noMatch": 2]))
        XCTAssertTrue(small.first { $0.name == "coveredTop1" }!.detail.hasPrefix("not evaluated"), "0 or too few cases never pass")

        let table = Self.sweep(outcomes, thresholds: [0.5, 0.75, 0.95])
        XCTAssertEqual(table[0]["noMatchCorrect"] as? Double, 0)
        XCTAssertEqual(table[1]["noMatchCorrect"] as? Double, 0.5)
        XCTAssertEqual(table[2]["noMatchCorrect"] as? Double, 1)
        XCTAssertEqual(table[2]["coveredTop10"] as? Double, 0, "everything abstains at 0.95")
        XCTAssertEqual(Self.chosenThreshold(table, noMatchFloor: 0.5), 0.75)
        XCTAssertNil(Self.chosenThreshold(Self.sweep(outcomes, thresholds: [0.5]), noMatchFloor: 1))
    }

    // MARK: The evaluation (opt-in)

    func testPhotoEvaluation() async throws {
        guard let reportPath = ProcessInfo.processInfo.environment["DIVEID_PHOTO_EVAL_REPORT"] else {
            throw XCTSkip("Set DIVEID_PHOTO_EVAL_REPORT to run the photo evaluation (Docs/PhotoEvaluation.md).")
        }
        try XCTSkipUnless(VisionFeaturePrint.isAvailable, "needs Apple Vision")
        let split = ProcessInfo.processInfo.environment["DIVEID_PHOTO_EVAL_SPLIT"] ?? "holdout"
        let colourCorrected = ProcessInfo.processInfo.environment["DIVEID_PHOTO_EVAL_COLOUR"] == "1"
        let directory = root.appendingPathComponent("Data/PhotoEvaluation")
        let manifestURL = directory.appendingPathComponent(split == "holdout" ? "Holdout.v1.json" : "Development.v1.json")
        let manifestData = try Data(contentsOf: manifestURL)
        if split == "holdout" {
            struct Freeze: Decodable { let holdoutManifestSHA256: String }
            let freezeURL = directory.appendingPathComponent("Freeze.json")
            guard let frozen = try? JSONDecoder().decode(Freeze.self, from: Data(contentsOf: freezeURL)) else {
                return XCTFail("The held-out manifest isn't frozen: run `python3 Tools/SpeciesPhotos/holdout.py freeze` before the first run.")
            }
            guard Self.sha256(manifestData) == frozen.holdoutManifestSHA256 else {
                return XCTFail("Holdout.v1.json doesn't match the hash frozen in Freeze.json; refusing to evaluate.")
            }
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        let rules = try JSONDecoder().decode(GateProtocol.self, from: Data(contentsOf: root.appendingPathComponent("Data/Evaluation/PhotoProtocol.v1.json")))

        let repository = BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleThenDevelopmentSource, access: .publication)
        let pack = try await repository.loadPack(id: .global)
        let environment = ProcessInfo.processInfo.environment
        let provider: any PhotoRecognizerProviding
        if let name = environment["DIVEID_PHOTO_EVAL_CANDIDATE"] {
#if canImport(CoreML) && canImport(Vision)
            guard let candidate = PhotoModelCandidate(rawValue: name), let directory = environment["DIVEID_PHOTO_CANDIDATES"] else {
                return XCTFail("DIVEID_PHOTO_EVAL_CANDIDATE needs bioclip or dinov2, and DIVEID_PHOTO_CANDIDATES")
            }
            provider = try await CandidateProvider.load(directory: URL(fileURLWithPath: directory), candidate: candidate,
                                                        variant: environment["DIVEID_PHOTO_EVAL_VARIANT"] ?? "photos")
#else
            throw XCTSkip("candidates need Core ML")
#endif
        } else {
            provider = BundledPhotoIndexProvider.bundled(TestResources.productionBundle)
        }
        guard let recognizer = try await provider.recognizer(for: pack) else { return XCTFail("no recognizer for Global") }
        let service = LocalMarineLifeIdentificationService(catalogRepository: repository,
                                                           photoIdentification: PhotoIdentificationService(recognizers: provider),
                                                           features: .forChannel(.debug))
        var outcomes: [Outcome] = [], missing: [String] = []
        let start = ContinuousClock.now
        for photo in manifest.photos {
            let file = directory.appendingPathComponent("cache/inat-\(photo.photoID.split(separator: ":").last ?? "").jpg")
            guard let data = try? Data(contentsOf: file), let expectedHash = photo.sha256, Self.sha256(data) == expectedHash else {
                missing.append(photo.photoID)
                continue
            }
            let processed = try ProcessedPhoto(id: UUID(), previewData: data, uploadData: data, pixelWidth: 0, pixelHeight: 0, format: .jpeg)
                .preparedForRecognition(region: .full, colourCorrected: colourCorrected)
            let raw = try await recognizer.recognize(processed, catalogueContentVersion: pack.photoCatalogueContentVersion)
            let result = try await service.identifyOutcome(request: .init(source: .processedPhoto(processed.reference), context: .init(region: .global)),
                                                           processedPhoto: processed)
            let rank = photo.speciesID.flatMap { id in result.matches.firstIndex { $0.species.id == id }.map { $0 + 1 } }
            let rawRank = photo.speciesID.flatMap { id in raw.candidates.firstIndex { $0.speciesID == id }.map { $0 + 1 } }
            let compliant = result.matches.allSatisfy { $0.score <= LocalRankingWeights.limitedConfidenceCap && $0.score.isFinite
                && $0.matchStrength != .strong && $0.matchStrength != .good }
            outcomes.append(Outcome(photoID: photo.photoID, expected: photo.expected, group: photo.group, covered: photo.covered,
                                    underwater: photo.underwater, rank: rank, abstained: result.photoSummary?.abstained ?? true,
                                    compliant: compliant, topSimilarity: raw.candidates.first?.similarity.normalized ?? 0, rawRank: rawRank))
        }
        let elapsed = ContinuousClock.now - start
        let buckets = Self.buckets(outcomes)
        var report: [String: Any] = [
            "schemaVersion": 1, "split": split, "manifest": manifestURL.lastPathComponent, "manifestSHA256": Self.sha256(manifestData),
            "protocolStatus": rules.status, "recognizer": recognizer.recognizerID, "recognizerVersion": recognizer.version,
            "abstainSimilarity": recognizer.abstainSimilarity, "colourCorrected": colourCorrected, "photos": manifest.photos.count, "evaluated": outcomes.count,
            "missingPhotos": missing.count, "platform": "host (Mac); phone feature prints differ slightly (Tools/PhotoIndex/README.md)",
            "seconds": Double(elapsed.components.seconds), "buckets": buckets.mapValues(\.summary),
        ]
        if split == "holdout" {
            let results = Self.gates(buckets, rules)
            report["gates"] = results.map { ["gate": $0.name, "passed": $0.passed, "detail": $0.detail] }
            for result in results where !result.passed { XCTFail("photo gate \(result.name) failed: \(result.detail)") }
            if !missing.isEmpty { XCTFail("\(missing.count) held-out photos are missing or changed; download them before evaluating") }
        } else {
            let table = Self.sweep(outcomes)
            report["thresholdSweep"] = table
            report["chosenThreshold"] = Self.chosenThreshold(table, noMatchFloor: rules.minimumRates["noMatchCorrect"] ?? 1) as Any
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let url = reportPath.hasPrefix("/") ? URL(fileURLWithPath: reportPath) : root.appendingPathComponent(reportPath)
        try data.write(to: url, options: .atomic)
        print("PHOTOEVAL \(split): \(outcomes.count) photos, covered \(buckets["covered"]?.summary ?? [:]), noMatch \(buckets["noMatch"]?.summary ?? [:])")
    }

    static func sha256(_ data: Data) -> String {
#if canImport(CryptoKit)
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
#else
        PhotoReferenceIndex.sha256Hex(data)
#endif
    }
}
