import XCTest
@testable import DiveID
#if canImport(PhotoIndexBuilder)
import PhotoIndexBuilder
#endif
#if canImport(CoreML) && canImport(Vision)
import CoreML
import Vision
#endif

// Candidate image models for photo identification (Docs/PhotoModelCandidates.md). This
// file is test code: it is never compiled into the app, and the models and indexes live
// outside the repository (DIVEID_PHOTO_CANDIDATES, a directory with one folder per
// candidate holding model.mlpackage from Tools/PhotoModels/convert.py).

/// Candidate codes recorded in an index header, in place of the Vision request revision.
enum PhotoModelCandidate: String, CaseIterable {
    case bioclip, dinov2

    var code: Int { self == .bioclip ? 1001 : 1002 }
    /// The model's name when copied into the test bundle (DiveIDTests/CandidateModels, git-ignored).
    var bundledName: String { self == .bioclip ? "BioCLIP" : "DINOv2" }
}

#if canImport(CoreML) && canImport(Vision)
/// A Core ML image model whose output is an L2-normalized embedding of a 224 × 224
/// centre crop, run through Vision so scaling matches between the index and queries.
final class CoreMLImageEmbedder: @unchecked Sendable {
    private let model: VNCoreMLModel
    private let lock = NSLock()

    init(compiledModelURL: URL) throws {
        let configuration = MLModelConfiguration()
#if targetEnvironment(simulator)
        configuration.computeUnits = .cpuOnly  // the simulator has no Neural Engine context
#endif
        model = try VNCoreMLModel(for: MLModel(contentsOf: compiledModelURL, configuration: configuration))
    }

    /// The compiled model next to the package, compiling it on first use.
    static func compiled(_ package: URL) async throws -> URL {
        let compiled = package.deletingPathExtension().appendingPathExtension("mlmodelc")
        if FileManager.default.fileExists(atPath: compiled.path) { return compiled }
        let temporary = try await MLModel.compileModel(at: package)
        try? FileManager.default.removeItem(at: compiled)
        try FileManager.default.moveItem(at: temporary, to: compiled)
        return compiled
    }

    func vector(_ data: Data) throws -> [Float] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .centerCrop
        lock.lock(); defer { lock.unlock() }
        try VNImageRequestHandler(data: data, options: [:]).perform([request])
        guard let array = (request.results?.first as? VNCoreMLFeatureValueObservation)?.featureValue.multiArrayValue else {
            throw PhotoIndexError.featurePrintUnavailable
        }
        return PhotoReferenceIndex.normalized((0..<array.count).map { array[$0].floatValue })
    }
}

/// Nearest-neighbour matching against a candidate's own reference index.
struct EmbeddingPhotoRecognizer: PhotoRecognizer {
    let candidate: PhotoModelCandidate
    let index: PhotoReferenceIndex
    let embedder: CoreMLImageEmbedder
    let abstainSimilarity: Double
    let label: String

    var recognizerID: String { "candidate-\(label)" }
    var version: String { "\(candidate.code)/\(index.catalogueContentVersion)" }
    var coveredSpeciesIDs: Set<UUID> { index.coveredSpeciesIDs }
    var isPlaceholder: Bool { false }

    func recognize(_ photo: ProcessedPhoto, catalogueContentVersion: String) async throws -> PhotoRecognition {
        guard catalogueContentVersion == index.catalogueContentVersion else {
            throw PhotoIndexError.catalogueMismatch(index: index.catalogueContentVersion, app: catalogueContentVersion)
        }
        let query = try embedder.vector(photo.uploadData)
        try Task.checkCancellation()
        return PhotoRecognition(candidates: index.nearestSpecies(to: query, limit: VisionPhotoRecognizer.candidateLimit).map {
            PhotoRecognitionCandidate(speciesID: $0.speciesID, similarity: .init(value: Double($0.cosine), scale: .cosine),
                                      evidence: .init(referenceID: "\(label):\($0.fileName)", referenceFileName: $0.fileName))
        })
    }
}

/// One candidate (a model plus one of its indexes) for the evaluation.
struct CandidateProvider: PhotoRecognizerProviding {
    let recognizer: EmbeddingPhotoRecognizer

    /// `variant` "photos" uses the 1,934 reference photos; "photos+text" (BioCLIP) adds a
    /// species-name text vector for every species without a photo.
    static func load(directory: URL, candidate: PhotoModelCandidate, variant: String = "photos", abstainSimilarity: Double = 0.5) async throws -> CandidateProvider {
        let folder = directory.appendingPathComponent(candidate.rawValue)
        return try load(compiledModel: try await CoreMLImageEmbedder.compiled(folder.appendingPathComponent("model.mlpackage")),
                        index: folder.appendingPathComponent(variant == "photos" ? "index.bin" : "index-text.bin"),
                        candidate: candidate, variant: variant, abstainSimilarity: abstainSimilarity)
    }

    /// From the test bundle (Xcode compiles the copied .mlpackage), for the device and simulator.
    static func loadFromTestBundle(_ bundle: Bundle, candidate: PhotoModelCandidate, variant: String = "photos") throws -> CandidateProvider? {
        guard let model = bundle.url(forResource: candidate.bundledName, withExtension: "mlmodelc"),
              let index = bundle.url(forResource: "\(candidate.rawValue)-\(variant == "photos" ? "index" : "index-text")", withExtension: "bin") else { return nil }
        return try load(compiledModel: model, index: index, candidate: candidate, variant: variant, abstainSimilarity: 0.5)
    }

    static func load(compiledModel: URL, index indexURL: URL, candidate: PhotoModelCandidate, variant: String, abstainSimilarity: Double) throws -> CandidateProvider {
        let embedder = try CoreMLImageEmbedder(compiledModelURL: compiledModel)
        let index = try PhotoReferenceIndex.decode(Data(contentsOf: indexURL))
        guard index.requestRevision == candidate.code else { throw PhotoIndexError.requestRevisionMismatch(index: index.requestRevision, app: candidate.code) }
        return CandidateProvider(recognizer: EmbeddingPhotoRecognizer(candidate: candidate, index: index, embedder: embedder,
                                                                      abstainSimilarity: abstainSimilarity, label: "\(candidate.rawValue)-\(variant)"))
    }

    func recognizer(for pack: OfflineIdentificationPack) async throws -> (any PhotoRecognizer)? {
        guard pack.photoCatalogueContentVersion == recognizer.index.catalogueContentVersion else {
            throw PhotoIndexError.catalogueMismatch(index: recognizer.index.catalogueContentVersion, app: pack.photoCatalogueContentVersion)
        }
        return recognizer
    }
}
#endif

final class PhotoModelCandidateTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    private func candidatesDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["DIVEID_PHOTO_CANDIDATES"] else {
            throw XCTSkip("Set DIVEID_PHOTO_CANDIDATES to the converted candidates (Docs/PhotoModelCandidates.md).")
        }
        return URL(fileURLWithPath: path)
    }

#if canImport(PhotoIndexBuilder) && canImport(CoreML) && canImport(Vision)
    /// Builds each candidate's reference index from the approved bundled photos, with the
    /// photo index tool's builder (licence and missing-photo checks included). BioCLIP also
    /// gets index-text.bin: the photos plus a species-name text vector for every species
    /// without a photo (Tools/PhotoModels/convert.py writes text-vectors.json).
    func testBuildCandidateIndexes() async throws {
        let directory = try candidatesDirectory()
        let pack = root.appendingPathComponent("DiveID/Resources/IdentificationPacks/Global")
        for candidate in PhotoModelCandidate.allCases {
            let folder = directory.appendingPathComponent(candidate.rawValue)
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("model.mlpackage").path) else { continue }
            let embedder = try CoreMLImageEmbedder(compiledModelURL: try await CoreMLImageEmbedder.compiled(folder.appendingPathComponent("model.mlpackage")))
            let start = ContinuousClock.now
            let builder = try PhotoIndexBuilder(packDirectory: pack, packID: "global", policyURL: root.appendingPathComponent("Tools/SpeciesPhotos/photo_policy.json"),
                                                requestRevision: candidate.code) { url in try embedder.vector(Data(contentsOf: url)) }
            let (index, sidecar) = try builder.build()
            try PhotoIndexBuilder.write(index, sidecar, index: folder.appendingPathComponent("index.bin"), sidecar: folder.appendingPathComponent("index.json"))
            print("CANDIDATE \(candidate.rawValue) index: \(index.entries.count) photos × \(index.dimension), \(index.encoded().count) bytes, \(ContinuousClock.now - start)")

            let textURL = folder.appendingPathComponent("text-vectors.json")
            guard candidate == .bioclip, let textData = try? Data(contentsOf: textURL) else { continue }
            struct TextVector: Decodable { let speciesID: UUID; let vector: [Float] }
            let covered = index.coveredSpeciesIDs
            let text = try JSONDecoder().decode([TextVector].self, from: textData).filter { !covered.contains($0.speciesID) }
            var vectors: [[Float]] = (0..<index.entries.count).map { Array(index.vectors[($0 * index.dimension)..<(($0 + 1) * index.dimension)]) }
            vectors += text.map(\.vector)
            let combined = try PhotoReferenceIndex(requestRevision: index.requestRevision, catalogueContentVersion: index.catalogueContentVersion,
                                                   dimension: index.dimension, entries: index.entries + text.map { .init(speciesID: $0.speciesID, fileName: "text:\($0.speciesID.uuidString)") },
                                                   vectors: vectors)
            try combined.encoded().write(to: folder.appendingPathComponent("index-text.bin"))
            print("CANDIDATE bioclip text index: \(combined.entries.count) entries (\(text.count) species by name), \(combined.encoded().count) bytes")
        }
    }
#endif

#if canImport(CoreML) && canImport(Vision)
    /// Load time, memory and per-query latency for each candidate, and parity between the
    /// prints computed here and the index built on the Mac. Reported, not gated. Run in the
    /// simulator with TEST_RUNNER_DIVEID_PHOTO_CANDIDATES set.
    func testMeasureCandidates() async throws {
        // A folder on the Mac (DIVEID_PHOTO_CANDIDATES), or the models copied into this test bundle.
        let directory = ProcessInfo.processInfo.environment["DIVEID_PHOTO_CANDIDATES"].map { URL(fileURLWithPath: $0) }
        let testBundle = Bundle(for: PhotoModelCandidateTests.self)
        guard directory != nil || testBundle.url(forResource: "BioCLIP", withExtension: "mlmodelc") != nil else {
            throw XCTSkip("Set DIVEID_PHOTO_CANDIDATES, or copy the candidates into DiveIDTests/CandidateModels (Docs/PhotoModelCandidates.md).")
        }
        let platform: String = {
#if targetEnvironment(simulator)
            "simulator"
#elseif os(iOS)
            "device"
#else
            "host"
#endif
        }()
        for candidate in PhotoModelCandidate.allCases {
            let before = Self.footprint()
            let start = ContinuousClock.now
            let loaded: CandidateProvider?
            if let directory {
                let folder = directory.appendingPathComponent(candidate.rawValue)
                loaded = FileManager.default.fileExists(atPath: folder.appendingPathComponent("index.bin").path)
                    ? try await CandidateProvider.load(directory: directory, candidate: candidate) : nil
            } else {
                loaded = try CandidateProvider.loadFromTestBundle(testBundle, candidate: candidate)
            }
            guard let provider = loaded else { continue }
            let load = ContinuousClock.now - start
            let index = provider.recognizer.index
            var times: [Duration] = [], cosines: [Float] = [], own = 0
            let sample = Array(stride(from: 3, to: index.entries.count, by: index.entries.count / 10).prefix(10))
            for position in sample {
                let entry = index.entries[position]
                let data = try Data(contentsOf: try XCTUnwrap(TestResources.productionBundle.url(
                    forResource: entry.fileName, withExtension: nil, subdirectory: "IdentificationPacks/Global/Images")))
                let t = ContinuousClock.now
                let vector = try provider.recognizer.embedder.vector(data)
                let matches = index.nearestSpecies(to: vector, limit: 20)
                times.append(ContinuousClock.now - t)
                let stored = index.vectors[(position * index.dimension)..<((position + 1) * index.dimension)]
                cosines.append(zip(vector, stored).reduce(Float(0)) { $0 + $1.0 * $1.1 })
                own += matches.first?.speciesID == entry.speciesID ? 1 : 0
            }
            let after = Self.footprint()
            func ms(_ d: Duration) -> String { String(format: "%.1f ms", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15) }
            let modelBytes = directory.map { Self.size($0.appendingPathComponent(candidate.rawValue).appendingPathComponent("model.mlpackage")) }
                ?? testBundle.url(forResource: candidate.bundledName, withExtension: "mlmodelc").map(Self.size) ?? 0
            let line = "CANDIDATE \(platform) \(candidate.rawValue): model \(modelBytes) bytes, index \(index.encoded().count) bytes; "
                + "load \(ms(load)); footprint change \(before.flatMap { b in after.map { String(format: "%.0f MiB", Double($0 - b) / 1_048_576) } } ?? "unavailable"); "
                + "query median \(ms(times.sorted()[times.count / 2])) max \(ms(times.max()!)); parity min cosine \(cosines.min() ?? 0), own species first \(own)/\(sample.count)"
            print(line)
            let report = FileManager.default.temporaryDirectory.appendingPathComponent("CANDIDATES.txt")
            try? (((try? String(contentsOf: report, encoding: .utf8)) ?? "") + line + "\n").write(to: report, atomically: true, encoding: .utf8)
        }
    }

    private static func size(_ url: URL) -> Int {
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])?.compactMap { $0 as? URL } ?? []
        if files.isEmpty { return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private static func footprint() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : nil
    }
#endif
}
