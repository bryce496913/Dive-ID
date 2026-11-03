import Foundation

/// Feature prints of the bundled reference photos, built on a Mac by Tools/PhotoIndex and
/// searched on the device. Public so the build tool shares this exact format.
///
/// Binary layout, little-endian:
/// - header: magic "DIPX", format version (UInt32), Vision request revision (UInt32),
///   vector dimension (UInt32), entry count (UInt32), catalogue content version (UInt16
///   byte length, then UTF-8);
/// - per entry: species ID (16 bytes), photo file name (UInt16 byte length, then UTF-8),
///   then `dimension` Float32 values, L2-normalized.
public struct PhotoReferenceIndex: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let speciesID: UUID
        public let fileName: String
        public init(speciesID: UUID, fileName: String) { self.speciesID = speciesID; self.fileName = fileName }
    }

    public static let formatVersion: UInt32 = 1
    static let magic = Data("DIPX".utf8)

    public let requestRevision: Int
    public let catalogueContentVersion: String
    public let dimension: Int
    public let entries: [Entry]
    /// `entries.count × dimension`, entry-major, each vector L2-normalized.
    public let vectors: [Float]

    public init(requestRevision: Int, catalogueContentVersion: String, dimension: Int, entries: [Entry], vectors: [[Float]]) throws {
        guard dimension > 0, vectors.count == entries.count, vectors.allSatisfy({ $0.count == dimension }) else {
            throw PhotoIndexError.malformed("vectors don't match the entries and dimension")
        }
        self.requestRevision = requestRevision
        self.catalogueContentVersion = catalogueContentVersion
        self.dimension = dimension
        self.entries = entries
        self.vectors = vectors.flatMap(Self.normalized)
    }

    private init(requestRevision: Int, catalogueContentVersion: String, dimension: Int, entries: [Entry], flat: [Float]) {
        self.requestRevision = requestRevision
        self.catalogueContentVersion = catalogueContentVersion
        self.dimension = dimension
        self.entries = entries
        vectors = flat
    }

    public var coveredSpeciesIDs: Set<UUID> { Set(entries.map(\.speciesID)) }

    /// "<source pack>-<FNV-1a 64 of the species file's bytes>", as the catalogue repository
    /// computes it for `OfflineIdentificationPack.photoReferenceVersion`.
    public static func catalogueContentVersion(packID: String, speciesData: Data) -> String {
        "\(packID)-" + StableDigest.fnv1a64Hex(speciesData)
    }

    public static func sha256Hex(_ data: Data) -> String { SHA256Digest.hex(data) }

    public static func normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? vector.map { $0 / norm } : vector
    }

    // MARK: Search

    public struct SpeciesMatch: Equatable, Sendable {
        public let speciesID: UUID
        /// The reference photo that matched best.
        public let fileName: String
        /// Cosine similarity, −1…1.
        public let cosine: Float
    }

    /// Brute force over every reference: the best reference per species, species best first.
    public func nearestSpecies(to query: [Float], limit: Int) -> [SpeciesMatch] {
        guard query.count == dimension, limit > 0 else { return [] }
        let q = Self.normalized(query)
        var best: [UUID: (index: Int, cosine: Float)] = [:]
        vectors.withUnsafeBufferPointer { all in
            q.withUnsafeBufferPointer { q in
                for index in entries.indices {
                    let base = index * dimension
                    var dot: Float = 0
                    for d in 0..<dimension { dot += all[base + d] * q[d] }
                    let id = entries[index].speciesID
                    if dot > best[id]?.cosine ?? -.infinity { best[id] = (index, dot) }
                }
            }
        }
        return best.map { SpeciesMatch(speciesID: $0.key, fileName: entries[$0.value.index].fileName, cosine: $0.value.cosine) }
            .sorted { $0.cosine != $1.cosine ? $0.cosine > $1.cosine : $0.speciesID.uuidString < $1.speciesID.uuidString }
            .prefix(limit).map { $0 }
    }

    // MARK: Encoding

    public func encoded() -> Data {
        var data = Self.magic
        data.appendLittleEndian(Self.formatVersion)
        data.appendLittleEndian(UInt32(requestRevision))
        data.appendLittleEndian(UInt32(dimension))
        data.appendLittleEndian(UInt32(entries.count))
        data.appendString(catalogueContentVersion)
        for (index, entry) in entries.enumerated() {
            withUnsafeBytes(of: entry.speciesID.uuid) { data.append(contentsOf: $0) }
            data.appendString(entry.fileName)
            for value in vectors[(index * dimension)..<((index + 1) * dimension)] { data.appendLittleEndian(value.bitPattern) }
        }
        return data
    }

    public static func decode(_ data: Data) throws -> PhotoReferenceIndex {
        var reader = ByteReader(data: data)
        guard try reader.bytes(4) == magic else { throw PhotoIndexError.malformed("not a photo index") }
        let format = try reader.uint32()
        guard format == formatVersion else { throw PhotoIndexError.unsupportedFormat(Int(format)) }
        let revision = Int(try reader.uint32()), dimension = Int(try reader.uint32()), count = Int(try reader.uint32())
        let version = try reader.string()
        guard dimension > 0, dimension <= 4_096, count <= 1_000_000 else { throw PhotoIndexError.malformed("implausible header") }
        var entries: [Entry] = []
        var vectors: [Float] = []
        entries.reserveCapacity(count)
        vectors.reserveCapacity(count * dimension)
        for _ in 0..<count {
            let raw = try reader.bytes(16)
            let uuid = raw.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
            entries.append(Entry(speciesID: uuid, fileName: try reader.string()))
            try reader.appendFloats(dimension, to: &vectors)
        }
        guard reader.isAtEnd else { throw PhotoIndexError.malformed("trailing bytes") }
        return PhotoReferenceIndex(requestRevision: revision, catalogueContentVersion: version, dimension: dimension, entries: entries, flat: vectors)
    }
}

public enum PhotoIndexError: Error, Equatable, Sendable, CustomStringConvertible {
    case missing
    case malformed(String)
    case unsupportedFormat(Int)
    case requestRevisionMismatch(index: Int, app: Int)
    case catalogueMismatch(index: String, app: String)
    case featurePrintUnavailable
    /// This device computes different prints from the Mac that built the index.
    case featurePrintMismatch(cosine: Float)

    public var description: String {
        switch self {
        case .missing: "PHOTO_INDEX_MISSING"
        case .malformed(let detail): "PHOTO_INDEX_MALFORMED (\(detail))"
        case .unsupportedFormat(let version): "PHOTO_INDEX_FORMAT \(version)"
        case .requestRevisionMismatch(let index, let app): "PHOTO_INDEX_REVISION index \(index), app \(app)"
        case .catalogueMismatch(let index, let app): "PHOTO_INDEX_STALE index \(index), app \(app)"
        case .featurePrintUnavailable: "PHOTO_FEATURE_PRINT_UNAVAILABLE"
        case .featurePrintMismatch(let cosine): "PHOTO_FEATURE_PRINT_MISMATCH cosine \(cosine)"
        }
    }
}

private struct ByteReader {
    let data: Data
    var offset = 0

    var isAtEnd: Bool { offset == data.count }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else { throw PhotoIndexError.malformed("truncated") }
        defer { offset += count }
        let start = data.startIndex + offset
        return data[start..<(start + count)]
    }

    mutating func uint32() throws -> UInt32 {
        try bytes(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }

    /// Reads `count` little-endian Float32 values in one pass (load time matters on the phone).
    mutating func appendFloats(_ count: Int, to output: inout [Float]) throws {
        let chunk = try bytes(count * 4)
        chunk.withUnsafeBytes { raw in
            for index in 0..<count {
                output.append(Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self))))
            }
        }
    }

    mutating func string() throws -> String {
        let length = try bytes(2).enumerated().reduce(Int(0)) { $0 | Int($1.element) << (8 * $1.offset) }
        guard let value = String(data: try bytes(length), encoding: .utf8) else { throw PhotoIndexError.malformed("bad text") }
        return value
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { append(UInt8((value >> UInt32(shift)) & 0xff)) }
    }

    mutating func appendString(_ value: String) {
        let bytes = Data(value.utf8)
        let length = UInt16(Swift.min(bytes.count, Int(UInt16.max)))
        append(UInt8(length & 0xff)); append(UInt8(length >> 8))
        append(bytes.prefix(Int(length)))
    }
}
