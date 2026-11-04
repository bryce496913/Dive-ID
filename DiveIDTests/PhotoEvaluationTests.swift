import XCTest
@testable import DiveID
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(CoreImage)
import CoreImage
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
/// DIVEID_PHOTO_EVAL_CALIBRATION=<development report> (held-out runs) reports every measure at
/// the threshold that development run chose for the same recognizer; it is never set here.
/// DIVEID_PHOTO_EVAL_UNUSABLE=1 adds unusable photos derived from the split's own species
/// photos (heavily blurred, nearly black) and a blank-water frame, which should all be
/// rejected. They are reported apart and never enter the approved gates.
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
        /// A wrong raw top-1 that the expected species' record lists as a similar species.
        var lookalikeConfusion = false
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
            if o.expected == "unusable" {
                out["unusable", default: Bucket()].add(o)
                continue  // reported apart: never in "all" or any gate
            }
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
                    "noMatchCorrect": rate(noMatch) { !answered($0) } as Any,
                    "unusableRejected": rate(outcomes.filter { $0.expected == "unusable" }) { !answered($0) } as Any]
        }
    }

    /// Every measure at one threshold (from the development split), from the raw output: a
    /// photo is answered when its best similarity reaches the threshold.
    static func atThreshold(_ outcomes: [Outcome], _ threshold: Double) -> [String: Any] {
        let answered = { (o: Outcome) in o.topSimilarity >= threshold }
        func rate(_ cases: [Outcome], _ hit: (Outcome) -> Bool) -> [String: Any] {
            let hits = cases.filter(hit).count
            return ["hits": hits, "cases": cases.count, "rate": cases.isEmpty ? NSNull() : Double(hits) / Double(cases.count) as Any]
        }
        let covered = outcomes.filter { $0.expected == "species" && $0.covered }
        let uncovered = outcomes.filter { $0.expected == "species" && !$0.covered }
        let noMatch = outcomes.filter { $0.expected == "noMatch" }
        let unusable = outcomes.filter { $0.expected == "unusable" }
        let coveredAnswered = covered.filter(answered)
        var groups: [String: Any] = [:]
        for group in Set(covered.map(\.group)).sorted() {
            let cases = covered.filter { $0.group == group }
            groups[group] = ["top1": rate(cases) { answered($0) && ($0.rawRank ?? .max) <= 1 }, "top3": rate(cases) { answered($0) && ($0.rawRank ?? .max) <= 3 }]
        }
        return [
            "threshold": threshold,
            "coverage": rate(covered, answered),
            "coveredTop1": rate(covered) { answered($0) && ($0.rawRank ?? .max) <= 1 },
            "coveredTop3": rate(covered) { answered($0) && ($0.rawRank ?? .max) <= 3 },
            "selectiveTop1": rate(coveredAnswered) { ($0.rawRank ?? .max) <= 1 },
            "lookalikeConfusions": rate(coveredAnswered) { $0.lookalikeConfusion },
            "uncoveredAnswered": rate(uncovered, answered),
            "noMatchCorrectRejection": rate(noMatch) { !answered($0) },
            "noMatchFalseAcceptance": rate(noMatch, answered),
            "unusableRejected": rate(unusable) { !answered($0) },
            "coveredByGroup": groups,
        ]
    }

    /// Calibration: how often the raw top-1 is right within each band of best similarity, over
    /// every photo (a no-match or unusable photo is never right). Similarities are not
    /// probabilities; this shows how far they are from behaving like one.
    static func reliability(_ outcomes: [Outcome], width: Double = 0.05) -> [[String: Any]] {
        var bands: [Int: (cases: Int, right: Int, similarity: Double)] = [:]
        for o in outcomes {
            let band = Int((o.topSimilarity / width).rounded(.down))
            let right = o.expected == "species" && o.covered && (o.rawRank ?? .max) <= 1
            let current = bands[band] ?? (0, 0, 0)
            bands[band] = (current.cases + 1, current.right + (right ? 1 : 0), current.similarity + o.topSimilarity)
        }
        return bands.keys.sorted().map { band in
            let value = bands[band]!
            return ["from": Double(band) * width, "to": Double(band + 1) * width, "cases": value.cases,
                    "meanSimilarity": value.similarity / Double(value.cases), "top1Right": Double(value.right) / Double(value.cases)]
        }
    }

    /// The threshold a development report chose, refused unless it was for this recognizer.
    static func calibratedThreshold(report data: Data, recognizer: String, version: String, colourCorrected: Bool) throws -> Double {
        let report = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        guard report["split"] as? String == "development" else { throw CalibrationError.notDevelopment }
        guard report["recognizer"] as? String == recognizer, report["recognizerVersion"] as? String == version,
              report["colourCorrected"] as? Bool == colourCorrected else { throw CalibrationError.otherRecognizer }
        guard let threshold = report["chosenThreshold"] as? Double else { throw CalibrationError.noThreshold }
        return threshold
    }

    enum CalibrationError: Error, Equatable { case notDevelopment, otherRecognizer, noThreshold }

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

    func testMeasuresAtACalibratedThresholdAndCalibrationTable() throws {
        func o(_ expected: String, covered: Bool = true, top: Double, raw: Int?, group: String = "fish", lookalike: Bool = false) -> Outcome {
            var outcome = Outcome(photoID: UUID().uuidString, expected: expected, group: group, covered: covered, underwater: nil, rank: nil,
                                  abstained: false, compliant: true, topSimilarity: top, rawRank: raw)
            outcome.lookalikeConfusion = lookalike
            return outcome
        }
        let outcomes = [o("species", top: 0.95, raw: 1), o("species", top: 0.91, raw: 2, lookalike: true), o("species", top: 0.80, raw: 1, group: "ray"),
                        o("species", covered: false, top: 0.92, raw: nil), o("noMatch", covered: false, top: 0.93, raw: nil),
                        o("noMatch", covered: false, top: 0.70, raw: nil), o("unusable", covered: false, top: 0.60, raw: nil)]
        let m = Self.atThreshold(outcomes, 0.9)
        func rate(_ key: String) -> Double? { (m[key] as? [String: Any])?["rate"] as? Double }
        XCTAssertEqual(rate("coverage"), 2.0 / 3.0, "two of three covered photos answered")
        XCTAssertEqual(rate("coveredTop1"), 1.0 / 3.0, "an unanswered photo counts as a miss")
        XCTAssertEqual(rate("selectiveTop1"), 0.5, "right among the answered")
        XCTAssertEqual(rate("lookalikeConfusions"), 0.5)
        XCTAssertEqual(rate("uncoveredAnswered"), 1)
        XCTAssertEqual(rate("noMatchCorrectRejection"), 0.5)
        XCTAssertEqual(rate("noMatchFalseAcceptance"), 0.5)
        XCTAssertEqual(rate("unusableRejected"), 1)
        XCTAssertNotNil((m["coveredByGroup"] as? [String: Any])?["ray"])

        let table = Self.reliability(outcomes, width: 0.1)
        let top = try XCTUnwrap(table.last)
        XCTAssertEqual(top["cases"] as? Int, 4, "0.9 to 1.0: three answered species-or-not plus the false acceptance")
        XCTAssertEqual(top["top1Right"] as? Double, 0.25)

        let buckets = Self.buckets(outcomes)
        XCTAssertEqual(buckets["unusable"]?.cases, 1)
        XCTAssertEqual(buckets["all"]?.cases, 6, "unusable photos never enter \"all\", so the approved gates are unchanged")
    }

    func testAHeldOutRunOnlyAcceptsTheThresholdItsOwnDevelopmentRunChose() throws {
        func report(_ fields: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: fields) }
        let good: [String: Any] = ["split": "development", "recognizer": "bioclip-photos", "recognizerVersion": "v1", "colourCorrected": false, "chosenThreshold": 0.87]
        XCTAssertEqual(try Self.calibratedThreshold(report: report(good), recognizer: "bioclip-photos", version: "v1", colourCorrected: false), 0.87)
        var held = good; held["split"] = "holdout"
        XCTAssertThrowsError(try Self.calibratedThreshold(report: report(held), recognizer: "bioclip-photos", version: "v1", colourCorrected: false))
        XCTAssertThrowsError(try Self.calibratedThreshold(report: report(good), recognizer: "dinov2-photos", version: "v1", colourCorrected: false))
        XCTAssertThrowsError(try Self.calibratedThreshold(report: report(good), recognizer: "bioclip-photos", version: "v1", colourCorrected: true))
        var none = good; none.removeValue(forKey: "chosenThreshold")
        XCTAssertThrowsError(try Self.calibratedThreshold(report: report(none), recognizer: "bioclip-photos", version: "v1", colourCorrected: false))
    }

#if canImport(CoreImage)
    func testUnusablePhotosAreDerivedAndLabelledAsSuch() throws {
        let image = try XCTUnwrap(TestResources.productionBundle.urls(forResourcesWithExtension: "jpg", subdirectory: "IdentificationPacks/Global/Images")?.first)
        let data = try Data(contentsOf: image)
        let derived = Self.unusablePhotos(from: [data, data, data, data, data])
        XCTAssertEqual(derived.count, 5, "two variants each of photos 1 and 5, and blank water")
        XCTAssertTrue(derived.allSatisfy { $0.photo.expected == "unusable" && $0.photo.speciesID == nil && $0.photo.photoID.hasPrefix("derived:") })
        XCTAssertTrue(derived.allSatisfy { $0.data != data })
    }
#endif

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

        let repository = TestResources.catalogRepository(resourceResolutionMode: .bundleThenDevelopmentSource, access: .publication)
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
        let similar = Dictionary(pack.profiles.map { ($0.id, Set($0.similarSpecies.map(\.speciesID))) }, uniquingKeysWith: { first, _ in first })
        var inputs: [(photo: Photo, data: Data)] = []
        for photo in manifest.photos {
            let file = directory.appendingPathComponent("cache/inat-\(photo.photoID.split(separator: ":").last ?? "").jpg")
            guard let data = try? Data(contentsOf: file), let expectedHash = photo.sha256, Self.sha256(data) == expectedHash else {
                missing.append(photo.photoID)
                continue
            }
            inputs.append((photo, data))
        }
        if environment["DIVEID_PHOTO_EVAL_UNUSABLE"] == "1" {
            inputs += Self.unusablePhotos(from: inputs.filter { $0.photo.expected == "species" }.map(\.data))
        }
        let start = ContinuousClock.now
        for (photo, data) in inputs {
            let processed = try ProcessedPhoto(id: UUID(), previewData: data, uploadData: data, pixelWidth: 0, pixelHeight: 0, format: .jpeg)
                .preparedForRecognition(region: .full, colourCorrected: colourCorrected)
            let raw = try await recognizer.recognize(processed, catalogueContentVersion: pack.photoCatalogueContentVersion)
            let result = try await service.identifyOutcome(request: .init(source: .processedPhoto(processed.reference), context: .init(region: .global)),
                                                           processedPhoto: processed)
            let rank = photo.speciesID.flatMap { id in result.matches.firstIndex { $0.species.id == id }.map { $0 + 1 } }
            let rawRank = photo.speciesID.flatMap { id in raw.candidates.firstIndex { $0.speciesID == id }.map { $0 + 1 } }
            let compliant = result.matches.allSatisfy { $0.score <= LocalRankingWeights.limitedConfidenceCap && $0.score.isFinite
                && $0.matchStrength != .strong && $0.matchStrength != .good }
            var outcome = Outcome(photoID: photo.photoID, expected: photo.expected, group: photo.group, covered: photo.covered,
                                  underwater: photo.underwater, rank: rank, abstained: result.photoSummary?.abstained ?? true,
                                  compliant: compliant, topSimilarity: raw.candidates.first?.similarity.normalized ?? 0, rawRank: rawRank)
            if let expected = photo.speciesID, let top = raw.candidates.first?.speciesID, top != expected {
                outcome.lookalikeConfusion = similar[expected]?.contains(top) == true
            }
            outcomes.append(outcome)
        }
        let elapsed = ContinuousClock.now - start
        let buckets = Self.buckets(outcomes)
        var report: [String: Any] = [
            "schemaVersion": 1, "split": split, "manifest": manifestURL.lastPathComponent, "manifestSHA256": Self.sha256(manifestData),
            "protocolStatus": rules.status, "recognizer": recognizer.recognizerID, "recognizerVersion": recognizer.version,
            "abstainSimilarity": recognizer.abstainSimilarity, "colourCorrected": colourCorrected, "photos": manifest.photos.count, "evaluated": outcomes.count,
            "missingPhotos": missing.count, "platform": "host (Mac); phone feature prints differ slightly (Tools/PhotoIndex/README.md)",
            "seconds": Double(elapsed.components.seconds), "buckets": buckets.mapValues(\.summary),
            "reliability": Self.reliability(outcomes),
            "unusablePhotos": outcomes.filter { $0.expected == "unusable" }.count,
            "scoreMeaning": "Normalized cosine similarity to the nearest reference photo. Not a probability; see reliability.",
        ]
        if let calibration = environment["DIVEID_PHOTO_EVAL_CALIBRATION"] {
            guard split == "holdout" else { return XCTFail("DIVEID_PHOTO_EVAL_CALIBRATION is for held-out runs; the development run chooses the threshold") }
            let url = calibration.hasPrefix("/") ? URL(fileURLWithPath: calibration) : root.appendingPathComponent(calibration)
            let threshold = try Self.calibratedThreshold(report: Data(contentsOf: url), recognizer: recognizer.recognizerID,
                                                         version: recognizer.version, colourCorrected: colourCorrected)
            report["calibration"] = ["developmentReport": url.lastPathComponent, "developmentReportSHA256": Self.sha256(try Data(contentsOf: url))]
            report["atCalibratedThreshold"] = Self.atThreshold(outcomes, threshold)
        }
        if split == "holdout" {
            let results = Self.gates(buckets, rules)
            report["gates"] = results.map { ["gate": $0.name, "passed": $0.passed, "detail": $0.detail] }
            for result in results where !result.passed { XCTFail("photo gate \(result.name) failed: \(result.detail)") }
            if !missing.isEmpty { XCTFail("\(missing.count) held-out photos are missing or changed; download them before evaluating") }
        } else {
            let table = Self.sweep(outcomes)
            report["thresholdSweep"] = table
            let chosen = Self.chosenThreshold(table, noMatchFloor: rules.minimumRates["noMatchCorrect"] ?? 1)
            report["chosenThreshold"] = chosen as Any
            if let chosen { report["atChosenThreshold"] = Self.atThreshold(outcomes, chosen) }
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let url = reportPath.hasPrefix("/") ? URL(fileURLWithPath: reportPath) : root.appendingPathComponent(reportPath)
        try data.write(to: url, options: .atomic)
        print("PHOTOEVAL \(split): \(outcomes.count) photos, covered \(buckets["covered"]?.summary ?? [:]), noMatch \(buckets["noMatch"]?.summary ?? [:])")
    }

    /// Photos a recognizer should reject: every fourth species photo heavily blurred and nearly
    /// black (derived from the same split, so nothing leaks between splits), and blank water.
    static func unusablePhotos(from species: [Data]) -> [(photo: Photo, data: Data)] {
#if canImport(CoreImage)
        let context = CIContext()
        func jpeg(_ image: CIImage) -> Data? {
            context.jpegRepresentation(of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
        }
        func photo(_ name: String, _ data: Data) -> (photo: Photo, data: Data) {
            (Photo(speciesID: nil, scientificName: name, group: "unusable", covered: false, expected: "unusable",
                   photoID: "derived:\(name):\(sha256(data).prefix(12))", underwater: nil, sha256: sha256(data)), data)
        }
        var out: [(photo: Photo, data: Data)] = []
        for data in species.enumerated().filter({ $0.offset % 4 == 0 }).map(\.element) {
            guard let image = CIImage(data: data) else { continue }
            if let blurred = jpeg(image.clampedToExtent().applyingGaussianBlur(sigma: 40).cropped(to: image.extent)) { out.append(photo("blurred", blurred)) }
            if let dark = jpeg(image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -6])) { out.append(photo("nearly black", dark)) }
        }
        let water = CIImage(color: CIColor(red: 0.05, green: 0.35, blue: 0.45)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
        if let blank = jpeg(water) { out.append(photo("blank water", blank)) }
        return out
#else
        return []
#endif
    }

    static func sha256(_ data: Data) -> String {
#if canImport(CryptoKit)
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
#else
        PhotoReferenceIndex.sha256Hex(data)
#endif
    }
}
