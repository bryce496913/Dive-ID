import Foundation

/// Search documents and the BM25 index for each catalogue content.
///
/// - **One build per content.** The key is the pack's identity and version, its record
///   count, the content fingerprint computed when the pack was built and the document
///   builder, so edited or filtered catalogues (for example the Release subset) get their
///   own entry. Concurrent requests for the same content share one build (a task), which
///   runs off this actor and off the main thread. A few entries are kept.
/// - **Cancellation.** A cancelled request stops waiting at once and throws
///   `CancellationError`; the shared build carries on and is reused by the next request.
/// - **Persistence.** When a directory is configured and the pack carries a stable
///   `persistentContentKey`, a built index is written to disk (`SearchIndexArchive`) and
///   a later launch loads it instead of rebuilding. An archive is used only when its
///   header matches this content, format, document schema, tokenizer and app build, its
///   checksum is intact, its records are exactly the pack's records, and sampled entries
///   rebuilt from their profiles are identical. Anything else is deleted and rebuilt.
actor SearchIndexStore {
    static let shared = SearchIndexStore(directory: defaultDirectory)

    /// The app's Caches directory; none in the portable SwiftPM build, so tests and
    /// evaluations never read or write user caches unless they pass a directory.
    static var defaultDirectory: URL? {
#if SWIFT_PACKAGE
        nil
#else
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DiveID/SearchIndex", isDirectory: true)
#endif
    }

    /// What happened to each index request, for tests and diagnostics.
    struct Statistics: Sendable, Equatable {
        var builds = 0
        var archiveLoads = 0
        var archiveRejections = 0
        var archiveWrites = 0
    }

    private let directory: URL?
    private let appBuild: String
    private let capacity: Int
    private var documentTasks: [String: Task<[SpeciesSearchDocument], Never>] = [:]
    private var indexTasks: [String: Task<BM25Index, Never>] = [:]
    private var order: [String] = []
    private var pendingWrites: [Task<Void, Never>] = []
    private(set) var statistics = Statistics()
#if DEBUG || DIVEID_INTERNAL
    private var outcomes: [String: SearchIndexOutcome] = [:]
#endif

    init(directory: URL?, appBuild: String = SearchIndexStore.currentAppBuild, capacity: Int = 6) {
        self.directory = directory
        self.appBuild = appBuild
        self.capacity = capacity
    }

    static var currentAppBuild: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "unversioned")(\(info["CFBundleVersion"] as? String ?? "0"))"
    }

    private func key(_ pack: OfflineIdentificationPack, _ builder: any SpeciesSearchDocumentBuilding) -> String {
        "\(pack.metadata.id.rawValue):\(pack.metadata.packVersion):\(pack.profiles.count):\(pack.contentFingerprint):\(String(reflecting: type(of: builder)))"
    }

    private func remember(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity {
            let evicted = order.removeFirst()
            documentTasks.removeValue(forKey: evicted)
            indexTasks.removeValue(forKey: evicted)
        }
    }

    func documents(pack: OfflineIdentificationPack, builder: any SpeciesSearchDocumentBuilding) async throws -> [SpeciesSearchDocument] {
        let key = key(pack, builder)
        let task: Task<[SpeciesSearchDocument], Never>
        if let existing = documentTasks[key] { task = existing } else {
            task = Task.detached(priority: Task.currentPriority) { pack.profiles.map { builder.document(from: $0, pack: pack.metadata) } }
            documentTasks[key] = task
        }
        remember(key)
        return try await Self.value(of: task)
    }

    func index(pack: OfflineIdentificationPack, builder: any SpeciesSearchDocumentBuilding) async throws -> BM25Index {
        try await Self.value(of: indexTask(pack: pack, builder: builder, priority: Task.currentPriority))
    }

    /// Starts loading or building the index in the background and returns at once. Used
    /// when the search screen opens, so the first search usually finds it ready.
    @discardableResult
    func prepare(pack: OfflineIdentificationPack, builder: any SpeciesSearchDocumentBuilding) -> Task<BM25Index, Never> {
        indexTask(pack: pack, builder: builder, priority: .utility)
    }

#if DEBUG || DIVEID_INTERNAL
    /// How this content's index was obtained on this launch (Internal diagnostics).
    func indexOutcome(pack: OfflineIdentificationPack, builder: any SpeciesSearchDocumentBuilding) -> SearchIndexOutcome? {
        outcomes[key(pack, builder)]
    }

    private func recordOutcome(_ source: SearchIndexSource, since start: ContinuousClock.Instant, key: String) {
        outcomes[key] = SearchIndexOutcome(source: source, duration: start.duration(to: .now))
    }

    /// This pack's stored index files (Internal delete and corrupt actions).
    func storedIndexURLs(for packID: OfflineIdentificationPackID) -> [URL] {
        guard let directory else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(packID.rawValue + "-") && $0.pathExtension == "bm25" }
    }
#endif

    /// Waits for archive writes started by earlier builds (tests).
    func waitForPendingWrites() async {
        let writes = pendingWrites
        pendingWrites.removeAll()
        for write in writes { await write.value }
    }

    private func indexTask(pack: OfflineIdentificationPack, builder: any SpeciesSearchDocumentBuilding, priority: TaskPriority) -> Task<BM25Index, Never> {
        let key = key(pack, builder)
        defer { remember(key) }
        if let existing = indexTasks[key] { return existing }
        let header = archiveHeader(pack, builder)
        let url = header.flatMap { archiveURL(pack, $0) }
        let task = Task.detached(priority: priority) { [weak self] () -> BM25Index in
#if DEBUG || DIVEID_INTERNAL
            let started = ContinuousClock.now
#endif
            if let stored = Self.storedIndex(url, header: header, pack: pack, builder: builder) {
                await self?.record(\.archiveLoads)
#if DEBUG || DIVEID_INTERNAL
                await self?.recordOutcome(.loadedFromStore, since: started, key: key)
#endif
                return stored
            }
            let invalidStore = url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            if let url, invalidStore {
                try? FileManager.default.removeItem(at: url)
                await self?.record(\.archiveRejections)
            }
            let index = Self.build(pack: pack, builder: builder)
            await self?.record(\.builds)
#if DEBUG || DIVEID_INTERNAL
            await self?.recordOutcome(invalidStore ? .rebuiltAfterInvalidStore : .built, since: started, key: key)
#endif
            if let url, let header { await self?.write(index, header: header, to: url, packID: pack.metadata.id) }
            return index
        }
        indexTasks[key] = task
        return task
    }

    private func record(_ counter: WritableKeyPath<Statistics, Int>) { statistics[keyPath: counter] += 1 }

    /// The validated stored index, or nil when there is none or it is not valid.
    private static func storedIndex(_ url: URL?, header: String?, pack: OfflineIdentificationPack, builder: any SpeciesSearchDocumentBuilding) -> BM25Index? {
        guard let url, let header, FileManager.default.fileExists(atPath: url.path) else { return nil }
#if DEBUG || DIVEID_INTERNAL
        let interval = SearchSignposts.begin(.indexLoadFromStore, pack.metadata.id.rawValue)
        let stored = SearchIndexArchive.read(url, header: header, pack: pack, builder: builder)
        SearchSignposts.end(interval, stored == nil ? "rejected" : "loaded")
        return stored
#else
        return SearchIndexArchive.read(url, header: header, pack: pack, builder: builder)
#endif
    }

    private static func build(pack: OfflineIdentificationPack, builder: any SpeciesSearchDocumentBuilding) -> BM25Index {
#if DEBUG || DIVEID_INTERNAL
        let interval = SearchSignposts.begin(.indexBuild, pack.metadata.id.rawValue)
        defer { SearchSignposts.end(interval) }
#endif
        return BM25Index(documents: pack.profiles.map { builder.document(from: $0, pack: pack.metadata) })
    }

    /// Written after the index is returned, so the first search never waits for the disk.
    private func write(_ index: BM25Index, header: String, to url: URL, packID: OfflineIdentificationPackID) {
        pendingWrites.append(Task.detached(priority: .utility) { [weak self] in
            guard SearchIndexArchive.write(index, header: header, to: url, removingOtherArchivesFor: packID) else { return }
            await self?.record(\.archiveWrites)
        })
    }

    /// Everything the stored index depends on besides the code version: format, document
    /// schema, tokenizer behaviour, app build, builder, pack identity and content.
    private func archiveHeader(_ pack: OfflineIdentificationPack, _ builder: any SpeciesSearchDocumentBuilding) -> String? {
        guard directory != nil, let content = pack.persistentContentKey else { return nil }
        return [
            "format=\(SearchIndexArchive.formatVersion)",
            "documents=\(SpeciesSearchDocument.schemaVersion)",
            "tokenizer=\(SearchIndexArchive.tokenizerProbe)",
            "app=\(appBuild)",
            "builder=\(String(reflecting: type(of: builder)))",
            "pack=\(pack.metadata.id.rawValue)@\(pack.metadata.packVersion)",
            "records=\(pack.profiles.count)",
            "content=\(content)"
        ].joined(separator: "\n")
    }

    private func archiveURL(_ pack: OfflineIdentificationPack, _ header: String) -> URL? {
        directory?.appendingPathComponent("\(pack.metadata.id.rawValue)-\(StableDigest.fnv1a64Hex(Data(header.utf8))).bm25")
    }

    /// Waits for a shared task, but returns as soon as the caller is cancelled.
    static func value<T: Sendable>(of task: Task<T, Never>) async throws -> T {
        try Task.checkCancellation()
        let once = ResumeOnce<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.install(continuation)
                Task { once.resume(.success(await task.value)) }
            }
        } onCancel: {
            once.resume(.failure(CancellationError()))
        }
    }
}

/// Resumes a continuation exactly once, whichever of completion and cancellation comes first.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// Starts preparing the selected pack's search index in the background, off the main
/// thread. It never blocks its caller; a failure leaves the first search to build it.
enum SearchIndexPreparation {
    static func start(packID: OfflineIdentificationPackID, catalog: any MarineSpeciesCatalogRepository,
                      store: SearchIndexStore = .shared, builder: any SpeciesSearchDocumentBuilding = SpeciesSearchDocumentBuilder()) {
        Task.detached(priority: .utility) {
            guard let pack = try? await catalog.loadPack(id: packID) else { return }
            _ = await store.prepare(pack: pack, builder: builder)
        }
    }
}

/// A stable, non-cryptographic digest for cache keys (FNV-1a, 64-bit). It detects any
/// accidental change to a catalogue resource; it is not a security boundary.
enum StableDigest {
    static func fnv1a64(_ bytes: some Sequence<UInt8>, seed: UInt64 = 0xcbf2_9ce4_8422_2325) -> UInt64 {
        var hash = seed
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash
    }

    static func fnv1a64(_ data: Data) -> UInt64 {
        data.withUnsafeBytes { fnv1a64($0.bindMemory(to: UInt8.self)) }
    }

    static func fnv1a64Hex(_ data: Data) -> String { String(format: "%016llx", fnv1a64(data)) }
}

/// The on-disk form of a BM25 index:
/// magic, format, header, vocabulary, entries (ID, length, names, term counts), then an
/// FNV-1a checksum of everything before it. Collection statistics are re-derived on load.
enum SearchIndexArchive {
    static let formatVersion: UInt32 = 1
    private static let magic = Array("DIVEBM25".utf8)

    /// A digest of the tokenizer's output on a fixed sentence that exercises morphology,
    /// relationships, negation and "-like" stems. A tokenizer change within one app build
    /// (during development) therefore invalidates stored archives too.
    static let tokenizerProbe: String = {
        let probe = "Leaf-like brown fish, tall front dorsal fin; blue and yellow stripes, front half paler than the rear, not red. Birdlike snout | Twospot Surgeonfish"
        return StableDigest.fnv1a64Hex(Data(BM25SpeciesCandidateRetriever.terms(probe).joined(separator: " ").utf8))
    }()

    static func encode(_ index: BM25Index, header: String) -> Data {
        var vocabulary: [String: UInt32] = [:]
        var terms: [String] = []
        for entry in index.entries {
            for term in entry.termFrequencies.keys.sorted() where vocabulary[term] == nil {
                vocabulary[term] = UInt32(terms.count)
                terms.append(term)
            }
        }
        var writer = Writer()
        writer.bytes(magic)
        writer.uint32(formatVersion)
        writer.string(header)
        writer.uint32(UInt32(terms.count))
        for term in terms { writer.string(term) }
        writer.uint32(UInt32(index.entries.count))
        for entry in index.entries {
            withUnsafeBytes(of: entry.speciesID.uuid) { writer.bytes(Array($0)) }
            writer.uint32(UInt32(entry.length))
            writer.uint32(UInt32(entry.normalizedNames.count))
            for name in entry.normalizedNames { writer.string(name) }
            let counts = entry.termFrequencies.sorted { $0.key < $1.key }
            writer.uint32(UInt32(counts.count))
            for (term, count) in counts {
                writer.uint32(vocabulary[term]!)
                writer.uint32(UInt32(count))
            }
        }
        writer.uint64(StableDigest.fnv1a64(writer.data))
        return Data(writer.data)
    }

    /// The header an archive was written with, without validating the rest (diagnostics).
    static func header(of data: Data) -> String? {
        var reader = Reader(bytes: [UInt8](data)[...])
        guard reader.bytes(magic.count) == magic, reader.uint32() == formatVersion else { return nil }
        return reader.string()
    }

    /// The stored index, or nil when the bytes are not an intact archive for `header`.
    static func decode(_ data: Data, header expected: String) -> BM25Index? {
        let bytes = [UInt8](data)
        guard bytes.count > magic.count + 12 else { return nil }
        let body = bytes[..<(bytes.count - 8)]
        var checksum: UInt64 = 0
        for (offset, byte) in bytes[(bytes.count - 8)...].enumerated() { checksum |= UInt64(byte) << (8 * UInt64(offset)) }
        guard StableDigest.fnv1a64(body) == checksum else { return nil }
        var reader = Reader(bytes: body)
        guard reader.bytes(magic.count) == magic, reader.uint32() == formatVersion, reader.string() == expected,
              let termCount = reader.uint32() else { return nil }
        var terms: [String] = []
        terms.reserveCapacity(Int(termCount))
        for _ in 0..<termCount {
            guard let term = reader.string() else { return nil }
            terms.append(term)
        }
        guard let entryCount = reader.uint32() else { return nil }
        var entries: [BM25Index.Entry] = []
        entries.reserveCapacity(Int(entryCount))
        for _ in 0..<entryCount {
            guard let id = reader.bytes(16), let length = reader.uint32(), let nameCount = reader.uint32() else { return nil }
            var names: [String] = []
            for _ in 0..<nameCount {
                guard let name = reader.string() else { return nil }
                names.append(name)
            }
            guard let countCount = reader.uint32() else { return nil }
            var frequencies: [String: Int] = [:]
            frequencies.reserveCapacity(Int(countCount))
            for _ in 0..<countCount {
                guard let term = reader.uint32(), let count = reader.uint32(), Int(term) < terms.count else { return nil }
                frequencies[terms[Int(term)]] = Int(count)
            }
            let uuid = UUID(uuid: (id[0], id[1], id[2], id[3], id[4], id[5], id[6], id[7], id[8], id[9], id[10], id[11], id[12], id[13], id[14], id[15]))
            entries.append(.init(speciesID: uuid, termFrequencies: frequencies, length: Int(length), normalizedNames: names))
        }
        guard reader.isAtEnd else { return nil }
        return BM25Index(entries: entries)
    }

    /// Reads and validates an archive for this pack. Beyond the header and checksum, the
    /// stored records must be exactly the pack's records, and entries rebuilt from a
    /// sample of profiles (first, middle and last by ID) must equal the stored ones.
    static func read(_ url: URL, header: String, pack: OfflineIdentificationPack, builder: any SpeciesSearchDocumentBuilding) -> BM25Index? {
        guard let data = try? Data(contentsOf: url), let index = decode(data, header: header),
              index.entries.count == pack.profiles.count,
              Set(index.entries.map(\.speciesID)) == Set(pack.profiles.map(\.id)) else { return nil }
        let stored = Dictionary(index.entries.map { ($0.speciesID, $0) }, uniquingKeysWith: { first, _ in first })
        let sorted = pack.profiles.sorted { $0.id.uuidString < $1.id.uuidString }
        let samples = Set([0, sorted.count / 2, sorted.count - 1].filter { sorted.indices.contains($0) })
        for position in samples {
            let profile = sorted[position]
            guard stored[profile.id] == BM25Index.entry(builder.document(from: profile, pack: pack.metadata)) else { return nil }
        }
        return index
    }

    /// Writes atomically, then removes this pack's archives for other content, formats or
    /// builds. Returns false when the write failed; the in-memory index is still used.
    @discardableResult
    static func write(_ index: BM25Index, header: String, to url: URL, removingOtherArchivesFor packID: OfflineIdentificationPackID) -> Bool {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encode(index, header: header).write(to: url, options: .atomic)
        } catch {
            return false
        }
        let siblings = (try? manager.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        for other in siblings where other.lastPathComponent != url.lastPathComponent
            && other.lastPathComponent.hasPrefix(packID.rawValue + "-") && other.pathExtension == "bm25" {
            try? manager.removeItem(at: other)
        }
        return true
    }

    private struct Writer {
        var data: [UInt8] = []
        mutating func bytes(_ value: [UInt8]) { data += value }
        mutating func uint32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data += $0 } }
        mutating func uint64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { data += $0 } }
        mutating func string(_ value: String) { let utf8 = Array(value.utf8); uint32(UInt32(utf8.count)); data += utf8 }
    }

    private struct Reader {
        let bytes: ArraySlice<UInt8>
        var position: Int
        init(bytes: ArraySlice<UInt8>) { self.bytes = bytes; position = bytes.startIndex }
        var isAtEnd: Bool { position == bytes.endIndex }
        mutating func bytes(_ count: Int) -> [UInt8]? {
            guard count >= 0, bytes.endIndex - position >= count else { return nil }
            defer { position += count }
            return Array(bytes[position..<(position + count)])
        }
        mutating func uint32() -> UInt32? {
            guard bytes.endIndex - position >= 4 else { return nil }
            var value: UInt32 = 0
            for offset in 0..<4 { value |= UInt32(bytes[position + offset]) << (8 * UInt32(offset)) }
            position += 4
            return value
        }
        mutating func string() -> String? {
            guard let count = uint32(), let utf8 = bytes(Int(count)) else { return nil }
            return String(decoding: utf8, as: UTF8.self)
        }
    }
}
