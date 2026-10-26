import Foundation

/// Cross-language fingerprint contract shared with `build_embedding_index.py`.
/// Both digests hash UTF-8 bytes of compact JSON with lexicographically sorted keys.
/// The vocabulary value is the decoded token-to-ID object (not its source-file layout).
/// The tokenizer value is the documented contract-field object plus tokenizer family
/// and the verified vocabulary digest.
enum FingerprintContract {
    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func identities(contract: SemanticModelArtifactContract, vocabulary: [String: Int]) throws
        -> (tokenizerFingerprint: String, vocabularySHA256: String) {
        let vocabularyData = try canonicalJSON(vocabulary)
        let vocabularyDigest = SHA256Digest.hex(vocabularyData)
        let identity: [String: Any] = [
            "tokenizerIdentifier": contract.tokenizerIdentifier,
            "preprocessingIdentifier": contract.preprocessingIdentifier,
            "lowercase": contract.lowercase, "stripAccents": contract.stripAccents,
            "maximumSequenceLength": contract.maximumSequenceLength,
            "truncation": contract.truncation.rawValue,
            "clsToken": contract.clsToken, "separatorToken": contract.separatorToken,
            "paddingToken": contract.paddingToken, "unknownToken": contract.unknownToken,
            "queryPrefix": contract.queryPrefix, "documentPrefix": contract.documentPrefix,
            "pooling": contract.pooling.rawValue, "normalizeL2": contract.normalizeL2,
            "tokenizerFamily": WordPieceTokenizer.family, "vocabularySHA256": vocabularyDigest
        ]
        return (SHA256Digest.hex(try canonicalJSON(identity)), vocabularyDigest)
    }

    private static func canonicalJSON(_ value: Any) throws -> Data {
        let object: [String: Any]
        if let typed = value as? [String: Int] { object = typed.mapValues { $0 as Any } }
        else if let typed = value as? [String: Any] { object = typed }
        else { throw SemanticArtifactDiagnostic.malformedTokenizer }
        // Keys in code-point order, as Python's sort_keys (Swift's String order is not defined that way).
        let keys = object.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) { $0.value < $1.value } }
        let members = try keys.map { key -> String in
            let encodedValue: String
            switch object[key]! {
            case let string as String: encodedValue = pythonJSONString(string)
            case let boolean as Bool: encodedValue = boolean ? "true" : "false"
            case let integer as Int: encodedValue = String(integer)
            default: throw SemanticArtifactDiagnostic.malformedTokenizer
            }
            return pythonJSONString(key) + ":" + encodedValue
        }
        return Data(("{" + members.joined(separator: ",") + "}").utf8)
    }

    /// A JSON string exactly as Python's `json.dumps(..., ensure_ascii=False)` writes it: only the
    /// quote, the backslash and C0 controls are escaped. JSONEncoder also escapes "/", which the real
    /// vocabulary contains ("/" and "##/"), so its digest never matched the provisioned contract.
    static func pythonJSONString(_ value: String) -> String {
        var output = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case _ where scalar.value < 0x20: output += String(format: "\\u%04x", scalar.value)
            default: output.unicodeScalars.append(scalar)
            }
        }
        return output + "\""
    }
}

enum SHA256Digest {
    private static let initial: [UInt32] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
    private static let constants: [UInt32] = [
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]
    static func hex(_ data: Data) -> String {
        var bytes = Array(data), length = UInt64(bytes.count) * 8
        bytes.append(0x80); while bytes.count % 64 != 56 { bytes.append(0) }
        bytes += (0..<8).reversed().map { UInt8((length >> UInt64($0 * 8)) & 0xff) }
        var hash = initial
        for offset in stride(from: 0, to: bytes.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 { let p = offset + index * 4; words[index] = UInt32(bytes[p]) << 24 | UInt32(bytes[p+1]) << 16 | UInt32(bytes[p+2]) << 8 | UInt32(bytes[p+3]) }
            for index in 16..<64 { let a = words[index-15], b = words[index-2]; words[index] = words[index-16] &+ (rotate(a,7) ^ rotate(a,18) ^ (a >> 3)) &+ words[index-7] &+ (rotate(b,17) ^ rotate(b,19) ^ (b >> 10)) }
            var a=hash[0],b=hash[1],c=hash[2],d=hash[3],e=hash[4],f=hash[5],g=hash[6],h=hash[7]
            for index in 0..<64 { let t1=h &+ (rotate(e,6)^rotate(e,11)^rotate(e,25)) &+ ((e&f)^((~e)&g)) &+ constants[index] &+ words[index]; let t2=(rotate(a,2)^rotate(a,13)^rotate(a,22)) &+ ((a&b)^(a&c)^(b&c)); h=g;g=f;f=e;e=d&+t1;d=c;c=b;b=a;a=t1&+t2 }
            hash[0]&+=a;hash[1]&+=b;hash[2]&+=c;hash[3]&+=d;hash[4]&+=e;hash[5]&+=f;hash[6]&+=g;hash[7]&+=h
        }
        return hash.map { String(format: "%08x", $0) }.joined()
    }
    private static func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 { (value >> count) | (value << (32-count)) }
}

/// Versioned sidecar shipped beside the compiled Core ML model. Index generation must
/// consume this same file; none of these values may be inferred at runtime.
struct SemanticModelArtifactContract: Codable, Hashable, Sendable {
    enum Pooling: String, Codable, Sendable { case meanMasked, cls, modelOutput }
    enum Truncation: String, Codable, Sendable { case end, beginning }

    let contractVersion: Int
    let modelIdentifier: String
    let modelVersion: String
    let embeddingDimension: Int
    let tokenizerIdentifier: String
    let preprocessingIdentifier: String
    let tokenizerFingerprint: String
    let vocabularySHA256: String
    let vocabularyFile: String
    let lowercase: Bool
    let stripAccents: Bool
    let maximumSequenceLength: Int
    let truncation: Truncation
    let clsToken: String
    let separatorToken: String
    let paddingToken: String
    let unknownToken: String
    let queryPrefix: String
    let documentPrefix: String
    let inputIDsFeature: String
    let attentionMaskFeature: String
    let tokenTypeIDsFeature: String?
    let outputFeature: String
    let pooling: Pooling
    let normalizeL2: Bool

    var cacheIdentity: String {
        [modelIdentifier, modelVersion, tokenizerIdentifier, preprocessingIdentifier,
         tokenizerFingerprint, vocabularySHA256, String(embeddingDimension),
         String(maximumSequenceLength)].joined(separator: ":")
    }

    func validate() throws {
        guard contractVersion == 1 else { throw SemanticArtifactDiagnostic.unsupportedContractVersion(contractVersion) }
        guard embeddingDimension > 0, maximumSequenceLength >= 2 else { throw SemanticArtifactDiagnostic.malformedContract }
        guard normalizeL2 else { throw SemanticArtifactDiagnostic.preprocessingUnsupported("normalizeL2 must be true") }
        guard FingerprintContract.isSHA256(tokenizerFingerprint), FingerprintContract.isSHA256(vocabularySHA256) else {
            throw SemanticArtifactDiagnostic.malformedContract
        }
    }

    /// Test/tooling helper for constructing a contract from an already decoded vocabulary.
    /// Production contracts remain signed by the provisioner and are only verified, never repaired.
    func binding(to vocabulary: [String: Int]) throws -> Self {
        let identities = try FingerprintContract.identities(contract: self, vocabulary: vocabulary)
        return Self(contractVersion: contractVersion, modelIdentifier: modelIdentifier, modelVersion: modelVersion,
            embeddingDimension: embeddingDimension, tokenizerIdentifier: tokenizerIdentifier,
            preprocessingIdentifier: preprocessingIdentifier, tokenizerFingerprint: identities.tokenizerFingerprint,
            vocabularySHA256: identities.vocabularySHA256, vocabularyFile: vocabularyFile, lowercase: lowercase,
            stripAccents: stripAccents, maximumSequenceLength: maximumSequenceLength, truncation: truncation,
            clsToken: clsToken, separatorToken: separatorToken, paddingToken: paddingToken, unknownToken: unknownToken,
            queryPrefix: queryPrefix, documentPrefix: documentPrefix, inputIDsFeature: inputIDsFeature,
            attentionMaskFeature: attentionMaskFeature, tokenTypeIDsFeature: tokenTypeIDsFeature,
            outputFeature: outputFeature, pooling: pooling, normalizeL2: normalizeL2)
    }
}

enum SemanticArtifactDiagnostic: Error, Equatable, Sendable, CustomStringConvertible {
    case experimentalEngineDisabled
    case missingContract(String)
    case missingModel(String)
    case missingTokenizer(String)
    case missingIndex(String)
    case unsupportedContractVersion(Int)
    case malformedContract
    case malformedTokenizer
    case preprocessingUnsupported(String)
    case malformedIndex
    case incompatibleIndex(SemanticIndexError)
    case coreMLUnavailable
    case modelInputMissing(String)
    case modelOutputMissing(String)
    case invalidModelOutputShape
    case unsupportedModelOutputDataType
    case unsupportedModelOutputLayout
    case invalidModelOutput
    case semanticRuntimeFailure

    var description: String {
        switch self {
        case .experimentalEngineDisabled: "experimental semantic engine disabled"
        case .missingContract(let value): "missing model contract: \(value)"
        case .missingModel(let value): "missing compiled model: \(value)"
        case .missingTokenizer(let value): "missing tokenizer vocabulary: \(value)"
        case .missingIndex(let value): "missing embedding index: \(value)"
        case .unsupportedContractVersion(let value): "unsupported contract version \(value)"
        case .malformedContract: "malformed model contract"
        case .malformedTokenizer: "malformed tokenizer vocabulary"
        case .preprocessingUnsupported(let value): "unsupported preprocessing: \(value)"
        case .malformedIndex: "malformed embedding index"
        case .incompatibleIndex(let value): "incompatible embedding index: \(value)"
        case .coreMLUnavailable: "Core ML is unavailable on this platform"
        case .modelInputMissing(let value): "model input missing: \(value)"
        case .modelOutputMissing(let value): "model output missing: \(value)"
        case .invalidModelOutputShape: "invalid model output shape"
        case .unsupportedModelOutputDataType: "unsupported model output data type"
        case .unsupportedModelOutputLayout: "unsupported model output layout"
        case .invalidModelOutput: "invalid model output"
        case .semanticRuntimeFailure: "semantic runtime failed"
        }
    }
}

/// Deterministic WordPiece tokenizer used by both synthetic adapter tests and Core ML.
/// The vocabulary is a JSON object mapping token strings to integer IDs.
struct WordPieceTokenizer: Sendable {
    let vocabulary: [String: Int]
    let contract: SemanticModelArtifactContract
    let tokenizerFingerprint: String
    let vocabularySHA256: String

    init(data: Data, contract: SemanticModelArtifactContract) throws {
        guard let vocabulary = try? JSONDecoder().decode([String: Int].self, from: data),
              vocabulary[contract.clsToken] != nil, vocabulary[contract.separatorToken] != nil,
              vocabulary[contract.paddingToken] != nil, vocabulary[contract.unknownToken] != nil else {
            throw SemanticArtifactDiagnostic.malformedTokenizer
        }
        let identities = try FingerprintContract.identities(contract: contract, vocabulary: vocabulary)
        guard identities.vocabularySHA256 == contract.vocabularySHA256,
              identities.tokenizerFingerprint == contract.tokenizerFingerprint else {
            throw SemanticArtifactDiagnostic.malformedTokenizer
        }
        self.vocabulary = vocabulary
        self.contract = contract
        vocabularySHA256 = identities.vocabularySHA256
        tokenizerFingerprint = identities.tokenizerFingerprint
    }

    /// Part of every tokenizer fingerprint (Tools/SemanticSearch/build_embedding_index.py
    /// `TOKENIZER_FAMILY`), so artifacts made with the earlier rule, which dropped
    /// punctuation, no longer validate.
    static let family = "BertWordPiece"
    static let maximumInputCharactersPerWord = 100

    func encode(_ input: String, document: Bool = false) -> (ids: [Int32], mask: [Int32]) {
        let text = (document ? contract.documentPrefix : contract.queryPrefix) + input
        let basic = Self.basicTokens(text, lowercase: contract.lowercase, stripAccents: contract.stripAccents)
        var pieces = basic.flatMap(wordPieces)
        let available = contract.maximumSequenceLength - 2
        if pieces.count > available {
            pieces = contract.truncation == .end ? Array(pieces.prefix(available)) : Array(pieces.suffix(available))
        }
        var ids = [vocabulary[contract.clsToken]!] + pieces.map { vocabulary[$0] ?? vocabulary[contract.unknownToken]! }
        ids.append(vocabulary[contract.separatorToken]!)
        var mask = [Int32](repeating: 1, count: ids.count)
        let padding = contract.maximumSequenceLength - ids.count
        ids += [Int](repeating: vocabulary[contract.paddingToken]!, count: padding)
        mask += [Int32](repeating: 0, count: padding)
        return (ids.map(Int32.init), mask)
    }

    /// BERT's basic tokenization, as the pinned fast tokenizer applies it (BertNormalizer then
    /// BertPreTokenizer), on Unicode scalars like the Python mirror `basic_tokens`:
    /// 1. drop NUL, U+FFFD and control, format, surrogate and private-use scalars, except tab,
    ///    newline and return; every whitespace scalar becomes a space;
    /// 2. put spaces around CJK ideographs;
    /// 3. strip accents (NFD, then drop nonspacing marks), then lowercase scalar by scalar;
    /// 4. split on whitespace; every punctuation scalar (ASCII punctuation or Unicode P*) is a
    ///    token of its own.
    static func basicTokens(_ text: String, lowercase: Bool, stripAccents: Bool) -> [String] {
        var cleaned = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\t" || scalar == "\n" || scalar == "\r" { cleaned.append(" "); continue }
            if scalar == "\u{0}" || scalar == "\u{FFFD}" { continue }
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse: continue
            default: break
            }
            if scalar.properties.isWhitespace {
                cleaned.append(" ")
            } else if isCJK(scalar) {
                cleaned.append(" "); cleaned.append(scalar); cleaned.append(" ")
            } else {
                cleaned.append(scalar)
            }
        }
        var scalars = Array(cleaned)
        if stripAccents {
            scalars = String(String.UnicodeScalarView(scalars)).decomposedStringWithCanonicalMapping.unicodeScalars
                .filter { $0.properties.generalCategory != .nonspacingMark }
        }
        if lowercase {
            scalars = scalars.flatMap { $0.properties.lowercaseMapping.unicodeScalars }
        }
        var tokens: [String] = [], current = String.UnicodeScalarView()
        func flush() {
            if !current.isEmpty { tokens.append(String(current)); current = String.UnicodeScalarView() }
        }
        for scalar in scalars {
            if scalar.properties.isWhitespace {
                flush()
            } else if isPunctuation(scalar) {
                flush(); tokens.append(String(scalar))
            } else {
                current.append(scalar)
            }
        }
        flush()
        return tokens
    }

    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII, "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".unicodeScalars.contains(scalar) { return true }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation: return true
        default: return false
        }
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0x2A700...0x2B73F,
             0x2B740...0x2B81F, 0x2B820...0x2CEAF, 0xF900...0xFAFF, 0x2F800...0x2FA1F: return true
        default: return false
        }
    }

    /// Greedy longest-match WordPiece over Unicode scalars; a word longer than
    /// `maximumInputCharactersPerWord` scalars, or one that cannot be split, is unknown.
    private func wordPieces(_ word: String) -> [String] {
        // As the pinned WordPiece model: the length limit comes before the vocabulary lookup.
        let scalars = Array(word.unicodeScalars)
        guard scalars.count <= Self.maximumInputCharactersPerWord else { return [contract.unknownToken] }
        if vocabulary[word] != nil { return [word] }
        var result: [String] = [], start = 0
        while start < scalars.count {
            var end = scalars.count, match: String?
            while start < end {
                let raw = String(String.UnicodeScalarView(scalars[start..<end]))
                let candidate = start == 0 ? raw : "##" + raw
                if vocabulary[candidate] != nil { match = candidate; break }
                end -= 1
            }
            guard let match else { return [contract.unknownToken] }
            result.append(match); start = end
        }
        return result
    }
}

#if canImport(CoreML)
@preconcurrency import CoreML

actor CoreMLSemanticEmbeddingProvider: SemanticEmbeddingProviding {
    nonisolated let modelIdentifier: String
    nonisolated let modelVersion: String
    nonisolated let embeddingDimension: Int
    nonisolated let tokenizerIdentifier: String
    nonisolated let preprocessingIdentifier: String
    nonisolated let tokenizerFingerprint: String
    nonisolated let vocabularySHA256: String
    private let model: MLModel
    private let tokenizer: WordPieceTokenizer
    private let contract: SemanticModelArtifactContract

    init(model: MLModel, tokenizer: WordPieceTokenizer, contract: SemanticModelArtifactContract) {
        self.model = model; self.tokenizer = tokenizer; self.contract = contract
        modelIdentifier = contract.modelIdentifier; modelVersion = contract.modelVersion
        embeddingDimension = contract.embeddingDimension; tokenizerIdentifier = contract.tokenizerIdentifier
        preprocessingIdentifier = contract.preprocessingIdentifier
        tokenizerFingerprint = tokenizer.tokenizerFingerprint
        vocabularySHA256 = tokenizer.vocabularySHA256
    }

    static func load(compiledModelURL: URL, contract: SemanticModelArtifactContract, vocabularyData: Data) async throws -> CoreMLSemanticEmbeddingProvider {
        try contract.validate()
        let tokenizer = try WordPieceTokenizer(data: vocabularyData, contract: contract)
        let configuration = MLModelConfiguration()
#if targetEnvironment(simulator)
        // The iOS simulator's Core ML has no MPSGraph engine, yet with all compute units it still
        // takes the GPU path and returns non-finite vectors; the CPU gives the real embedding.
        configuration.computeUnits = .cpuOnly
#endif
        let model = try MLModel(contentsOf: compiledModelURL, configuration: configuration)
        let requiredInputs = [contract.inputIDsFeature, contract.attentionMaskFeature] + (contract.tokenTypeIDsFeature.map { [$0] } ?? [])
        for name in requiredInputs where model.modelDescription.inputDescriptionsByName[name] == nil {
            throw SemanticArtifactDiagnostic.modelInputMissing(name)
        }
        guard model.modelDescription.outputDescriptionsByName[contract.outputFeature] != nil else {
            throw SemanticArtifactDiagnostic.modelOutputMissing(contract.outputFeature)
        }
        try validateOutputDescription(model.modelDescription.outputDescriptionsByName[contract.outputFeature]!, contract: contract)
        return CoreMLSemanticEmbeddingProvider(model: model, tokenizer: tokenizer, contract: contract)
    }

    private static func expectedOutputShape(for contract: SemanticModelArtifactContract) -> [Int] {
        switch contract.pooling {
        case .modelOutput: [1, contract.embeddingDimension]
        case .cls, .meanMasked: [1, contract.maximumSequenceLength, contract.embeddingDimension]
        }
    }

    private static func validateOutputDescription(_ description: MLFeatureDescription, contract: SemanticModelArtifactContract) throws {
        guard description.type == .multiArray, let constraint = description.multiArrayConstraint else {
            throw SemanticArtifactDiagnostic.unsupportedModelOutputDataType
        }
        guard constraint.dataType == .float32 || constraint.dataType == .float16 else {
            throw SemanticArtifactDiagnostic.unsupportedModelOutputDataType
        }
        guard constraint.shape.map(\.intValue) == expectedOutputShape(for: contract) else {
            throw SemanticArtifactDiagnostic.invalidModelOutputShape
        }
    }

    func embedding(for text: String) async throws -> [Float] {
        try Task.checkCancellation()
        let encoded = tokenizer.encode(text)
        let shape = [1, NSNumber(value: contract.maximumSequenceLength)]
        let ids = try MLMultiArray(shape: shape, dataType: .int32)
        let mask = try MLMultiArray(shape: shape, dataType: .int32)
        let types = try MLMultiArray(shape: shape, dataType: .int32)
        for offset in encoded.ids.indices {
            ids[offset] = NSNumber(value: encoded.ids[offset]); mask[offset] = NSNumber(value: encoded.mask[offset]); types[offset] = 0
        }
        var features: [String: MLFeatureValue] = [
            contract.inputIDsFeature: MLFeatureValue(multiArray: ids),
            contract.attentionMaskFeature: MLFeatureValue(multiArray: mask)
        ]
        if let name = contract.tokenTypeIDsFeature { features[name] = MLFeatureValue(multiArray: types) }
        let input = try MLDictionaryFeatureProvider(dictionary: features)
        let output = try await model.prediction(from: input)
        try Task.checkCancellation()
        guard let array = output.featureValue(for: contract.outputFeature)?.multiArrayValue else {
            throw SemanticArtifactDiagnostic.modelOutputMissing(contract.outputFeature)
        }
        return try Self.pool(array, mask: encoded.mask, contract: contract)
    }

    static func pool(_ array: MLMultiArray, mask: [Int32], contract: SemanticModelArtifactContract) throws -> [Float] {
        guard array.dataType == .float32 || array.dataType == .float16 else {
            throw SemanticArtifactDiagnostic.unsupportedModelOutputDataType
        }
        guard array.shape.map(\.intValue) == expectedOutputShape(for: contract) else {
            throw SemanticArtifactDiagnostic.invalidModelOutputShape
        }
        guard array.strides.count == array.shape.count, array.strides.allSatisfy({ $0.intValue > 0 }) else {
            throw SemanticArtifactDiagnostic.unsupportedModelOutputLayout
        }
        let embeddingDimension = contract.embeddingDimension
        func vectorValue(_ dimension: Int) -> Float {
            array[[NSNumber(value: 0), NSNumber(value: dimension)]].floatValue
        }
        func tokenValue(_ token: Int, _ dimension: Int) -> Float {
            array[[NSNumber(value: 0), NSNumber(value: token), NSNumber(value: dimension)]].floatValue
        }
        var vector: [Float]
        switch contract.pooling {
        case .modelOutput:
            vector = (0..<embeddingDimension).map(vectorValue)
        case .cls:
            vector = (0..<embeddingDimension).map { tokenValue(0, $0) }
        case .meanMasked:
            guard mask.count == contract.maximumSequenceLength else {
                throw SemanticArtifactDiagnostic.unsupportedModelOutputLayout
            }
            vector = [Float](repeating: 0, count: embeddingDimension)
            let count = max(1, mask.reduce(0) { $0 + Int($1) })
            for token in 0..<contract.maximumSequenceLength where mask[token] == 1 {
                for dimension in 0..<embeddingDimension { vector[dimension] += tokenValue(token, dimension) }
            }
            vector = vector.map { $0 / Float(count) }
        }
        guard vector.allSatisfy(\.isFinite) else { throw SemanticArtifactDiagnostic.invalidModelOutput }
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0 else { throw SemanticArtifactDiagnostic.invalidModelOutput }
        return vector.map { $0 / norm }
    }
}
#endif
