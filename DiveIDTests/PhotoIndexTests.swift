import XCTest
@testable import DiveID
#if canImport(Darwin)
import Darwin
#endif

/// The bundled Vision photo index: loading, rejection, parity with the build-time prints,
/// and measurements. Runs on the Mac (SwiftPM) and in the iOS simulator (Xcode); numbers
/// are printed with a "PHOTOINDEX <platform>" prefix.
final class PhotoIndexTests: XCTestCase {
    private var bundle: Bundle { TestResources.productionBundle }

    private static var platform: String {
#if targetEnvironment(simulator)
        "simulator"
#elseif os(iOS)
        "device"
#else
        "host"
#endif
    }

    private func repository() -> BundleMarineSpeciesCatalogRepository {
        TestResources.catalogRepository(access: .experimentalDevelopment)
    }

    private func indexData() throws -> Data {
        let url = try XCTUnwrap(bundle.url(forResource: "PhotoIndex", withExtension: "bin", subdirectory: "IdentificationPacks/Global"), "PhotoIndex.bin is bundled")
        return try Data(contentsOf: url)
    }

    private func photoData(_ fileName: String) throws -> Data {
        let url = try XCTUnwrap(bundle.url(forResource: fileName, withExtension: nil, subdirectory: "IdentificationPacks/Global/Images"))
        return try Data(contentsOf: url)
    }

    private static func provider(_ data: Data) -> BundledPhotoIndexProvider { BundledPhotoIndexProvider { data } }

    // MARK: The bundled index

    func testBundledIndexMatchesTheBundledGlobalCatalogue() async throws {
        let index = try PhotoReferenceIndex.decode(try indexData())
        let pack = try await repository().loadPack(id: .global)
        XCTAssertEqual(index.requestRevision, VisionFeaturePrint.requestRevision)
        XCTAssertEqual(index.catalogueContentVersion, pack.photoCatalogueContentVersion, "the index was built from this species file")
        let withPhotos = Set(pack.profiles.filter { $0.bundledImage != nil }.map(\.id))
        XCTAssertEqual(index.coveredSpeciesIDs, withPhotos, "coverage is every species with an approved bundled photo")
        XCTAssertEqual(Set(index.entries.map(\.fileName)), Set(pack.profiles.compactMap { $0.bundledImage?.fileName }))
    }

    func testRegionsDrawnFromGlobalUseTheGlobalIndexAndOtherPacksAreNotCovered() async throws {
        let provider = Self.provider(try indexData())
        let region = try await repository().loadPack(id: OfflineIdentificationPackID(rawValue: "tropical-atlantic"))
        let recognizer = try await provider.recognizer(for: region)
        XCTAssertNotNil(recognizer)
        XCTAssertEqual(recognizer?.isPlaceholder, false)
        let caribbean = try await repository().loadPack(id: .caribbean)
        let none = try await provider.recognizer(for: caribbean)
        XCTAssertNil(none, "the Caribbean pack has its own species file")
    }

    // MARK: Rejection

    func testStaleIndexIsRejectedNotUsed() async throws {
        let current = try PhotoReferenceIndex.decode(try indexData())
        let stale = try PhotoReferenceIndex(requestRevision: current.requestRevision, catalogueContentVersion: "global-0000000000000000",
                                            dimension: 2, entries: [current.entries[0]], vectors: [[1, 0]])
        let pack = try await repository().loadPack(id: .global)
        do {
            _ = try await Self.provider(stale.encoded()).recognizer(for: pack)
            XCTFail("a stale index must be rejected")
        } catch {
            XCTAssertEqual(error as? PhotoIndexError, .catalogueMismatch(index: "global-0000000000000000", app: pack.photoCatalogueContentVersion))
        }
    }

    func testOtherRequestRevisionIsRejected() async throws {
        let pack = try await repository().loadPack(id: .global)
        let other = try PhotoReferenceIndex(requestRevision: 1, catalogueContentVersion: pack.photoCatalogueContentVersion, dimension: 2,
                                            entries: [.init(speciesID: UUID(), fileName: "x.jpg")], vectors: [[1, 0]])
        do {
            _ = try await Self.provider(other.encoded()).recognizer(for: pack)
            XCTFail("another request revision must be rejected")
        } catch {
            XCTAssertEqual(error as? PhotoIndexError, .requestRevisionMismatch(index: 1, app: VisionFeaturePrint.requestRevision))
        }
    }

    func testRejectionShowsPhotoMatchingUnavailableNeverOtherResults() async throws {
        let photo = ProcessedPhoto(id: UUID(), previewData: Data([1]), uploadData: Data([1]), pixelWidth: 1, pixelHeight: 1, format: .jpeg)
        for provider in [BundledPhotoIndexProvider { throw PhotoIndexError.missing }, Self.provider(Data("damaged".utf8))] {
            let recognizers = ConfiguredPhotoRecognizerProvider(bundled: provider, fallback: StubPhotoRecognizerProvider())
            let service = LocalMarineLifeIdentificationService(
                catalogRepository: repository(),
                photoIdentification: PhotoIdentificationService(recognizers: recognizers), features: .forChannel(.debug))
            do {
                _ = try await service.identifyOutcome(request: .init(source: .processedPhoto(photo.reference), context: .init(region: .global)), processedPhoto: photo)
                XCTFail("expected photo matching to be unavailable")
            } catch {
                guard case .photoMatchingUnavailable(let code) = error as? LocalIdentificationError else { return XCTFail("\(error)") }
                XCTAssertTrue(code.hasPrefix("PHOTO_INDEX_"), code)
            }
        }
        let message = await IdentificationResultsViewModel.message(for: .photoMatchingUnavailable("PHOTO_INDEX_STALE x"), includesDiagnostics: false)
        XCTAssertEqual(message, AppCopy.photoMatchingUnavailable)
    }

    func testFirstUseChecksThatPrintsHereMatchTheIndex() async throws {
        try XCTSkipUnless(VisionFeaturePrint.isAvailable, "needs Apple Vision")
        let index = try PhotoReferenceIndex.decode(try indexData())
        let first = try photoData(index.entries[0].fileName), other = try photoData(index.entries[1].fileName)
        // Feeding a different photo stands in for a device whose prints differ from the Mac's.
        XCTAssertThrowsError(try BundledPhotoIndexProvider.checkParity(index) { _ in other }) { error in
            guard case .featurePrintMismatch = error as? PhotoIndexError else { return XCTFail("\(error)") }
        }
#if targetEnvironment(simulator)
        // The simulator's prints differ from the Mac's (see testFeaturePrintsHereMatchTheIndex), so it must refuse.
        XCTAssertThrowsError(try BundledPhotoIndexProvider.checkParity(index) { _ in first })
#else
        XCTAssertNoThrow(try BundledPhotoIndexProvider.checkParity(index) { _ in first })
#endif
    }

    func testIndexLoadsOnceOnFirstUse() async throws {
        let counter = LoadCounter()
        let data = try indexData()
        let provider = BundledPhotoIndexProvider { counter.increment(); return data }
        XCTAssertEqual(counter.value, 0, "nothing loads until photo identification is used")
        let pack = try await repository().loadPack(id: .global)
        _ = try await provider.recognizer(for: pack)
        _ = try await provider.recognizer(for: pack)
        XCTAssertEqual(counter.value, 1)
    }

    // MARK: Vision (Apple platforms)

    /// Prints of a sample of bundled photos, computed here, against the vectors in the
    /// index (built on a Mac). Tolerance (owner decision, 2026-10-29, from the iPhone 14 Pro
    /// figures): cosine ≥ 0.9 for every photo, median ≥ 0.98, and each photo's own species
    /// ranked first.
    func testFeaturePrintsHereMatchTheIndex() throws {
        try XCTSkipUnless(VisionFeaturePrint.isAvailable, "needs Apple Vision")
        let index = try PhotoReferenceIndex.decode(try indexData())
        let sample = Array(stride(from: 0, to: index.entries.count, by: max(1, index.entries.count / 12)).prefix(12))
        var cosines: [Float] = [], maxComponent: Float = 0, firstRanked = 0
        for position in sample {
            let entry = index.entries[position]
            let here = try VisionFeaturePrint.vector(imageData: try photoData(entry.fileName))
            let stored = Array(index.vectors[(position * index.dimension)..<((position + 1) * index.dimension)])
            cosines.append(zip(here, stored).reduce(Float(0)) { $0 + $1.0 * $1.1 })
            maxComponent = max(maxComponent, zip(here, stored).map { abs($0 - $1) }.max() ?? 0)
            if index.nearestSpecies(to: here, limit: 1).first?.speciesID == entry.speciesID { firstRanked += 1 }
        }
        Self.report("parity: \(sample.count) photos, minimum cosine \(cosines.min() ?? 0), median cosine \(cosines.sorted()[cosines.count / 2]), "
                    + "maximum component difference \(maxComponent), own species first \(firstRanked)/\(sample.count)")
        XCTAssertGreaterThanOrEqual(cosines.min() ?? 0, BundledPhotoIndexProvider.parityCosine, "prints here differ from the index built on the Mac")
        XCTAssertGreaterThanOrEqual(cosines.sorted()[cosines.count / 2], 0.98, "median parity")
        XCTAssertEqual(firstRanked, sample.count)
    }

    func testABundledPhotoFindsItsOwnSpeciesThroughTheService() async throws {
        try XCTSkipUnless(VisionFeaturePrint.isAvailable, "needs Apple Vision")
        let index = try PhotoReferenceIndex.decode(try indexData())
        let entry = index.entries[index.entries.count / 2]
        let data = try photoData(entry.fileName)
        let photo = ProcessedPhoto(id: UUID(), previewData: data, uploadData: data, pixelWidth: 400, pixelHeight: 400, format: .jpeg)
        let service = LocalMarineLifeIdentificationService(
            catalogRepository: repository(),
            photoIdentification: PhotoIdentificationService(recognizers: Self.provider(try indexData())), features: .forChannel(.debug))
        let outcome = try await service.identifyOutcome(request: .init(source: .processedPhoto(photo.reference), context: .init(region: .global)), processedPhoto: photo)
        XCTAssertEqual(outcome.matches.first?.species.id, entry.speciesID)
        XCTAssertEqual(outcome.matches.first?.photoEvidence?.referenceFileName, entry.fileName)
        XCTAssertLessThanOrEqual(outcome.matches.first?.score ?? 1, LocalRankingWeights.limitedConfidenceCap)
        XCTAssertEqual(outcome.photoSummary?.recognizerID, "vision-featureprint")
        XCTAssertEqual(outcome.photoSummary?.coveredSpeciesCount, index.coveredSpeciesIDs.count)
        XCTAssertEqual(outcome.photoSummary?.isPlaceholder, false)
    }

    /// Index size, load time, memory and per-query latency. Reported, not gated.
    func testMeasureIndexAndQueries() async throws {
        try XCTSkipUnless(VisionFeaturePrint.isAvailable, "needs Apple Vision")
        let data = try indexData()
        let before = Self.footprint()
        let provider = Self.provider(data)
        let start = ContinuousClock.now
        let index = try await provider.index()
        let load = ContinuousClock.now - start
        let after = Self.footprint()
        let queries = stride(from: 7, to: index.entries.count, by: max(1, index.entries.count / 10)).prefix(10).map { index.entries[$0].fileName }
        var printTimes: [Duration] = [], searchTimes: [Duration] = []
        for fileName in queries {
            let image = try photoData(fileName)
            let printStart = ContinuousClock.now
            let vector = try VisionFeaturePrint.vector(imageData: image)
            printTimes.append(ContinuousClock.now - printStart)
            let searchStart = ContinuousClock.now
            _ = index.nearestSpecies(to: vector, limit: VisionPhotoRecognizer.candidateLimit)
            searchTimes.append(ContinuousClock.now - searchStart)
        }
        func ms(_ d: Duration) -> String { String(format: "%.1f ms", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15) }
        func median(_ values: [Duration]) -> Duration { values.sorted()[values.count / 2] }
        let memory = (before != nil && after != nil) ? String(format: "%.1f MiB", Double(after! - before!) / 1_048_576) : "unavailable"
        let arrays = String(format: "%.1f MiB", Double(index.vectors.count * MemoryLayout<Float>.size) / 1_048_576)
        Self.report("measure: index \(data.count) bytes, \(index.entries.count) entries × \(index.dimension); "
              + "decode \(ms(load)); vectors in memory \(arrays); footprint change on load \(memory); "
              + "feature print median \(ms(median(printTimes))) max \(ms(printTimes.max()!)); "
              + "search median \(ms(median(searchTimes))) max \(ms(searchTimes.max()!)) over \(queries.count) queries")
        XCTAssertEqual(index.entries.count, 3926)
    }

    /// Printed, and appended to PHOTOINDEX.txt in the test's temporary directory (the
    /// simulator doesn't pass test output to xcodebuild).
    private static func report(_ line: String) {
        let text = "PHOTOINDEX \(platform) \(line)"
        print(text)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PHOTOINDEX.txt")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (existing + text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Physical footprint in bytes (Darwin), nil elsewhere.
    private static func footprint() -> Int? {
#if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : nil
#else
        nil
#endif
    }
}

final class LoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
