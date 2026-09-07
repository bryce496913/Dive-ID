import Foundation

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
         String(embeddingDimension), String(maximumSequenceLength)].joined(separator: ":")
    }

    func validate() throws {
        guard contractVersion == 1 else { throw SemanticArtifactDiagnostic.unsupportedContractVersion(contractVersion) }
        guard embeddingDimension > 0, maximumSequenceLength >= 2 else { throw SemanticArtifactDiagnostic.malformedContract }
        guard normalizeL2 else { throw SemanticArtifactDiagnostic.preprocessingUnsupported("normalizeL2 must be true") }
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

    init(data: Data, contract: SemanticModelArtifactContract) throws {
        guard let vocabulary = try? JSONDecoder().decode([String: Int].self, from: data),
              vocabulary[contract.clsToken] != nil, vocabulary[contract.separatorToken] != nil,
              vocabulary[contract.paddingToken] != nil, vocabulary[contract.unknownToken] != nil else {
            throw SemanticArtifactDiagnostic.malformedTokenizer
        }
        self.vocabulary = vocabulary
        self.contract = contract
    }

    func encode(_ input: String, document: Bool = false) -> (ids: [Int32], mask: [Int32]) {
        var text = (document ? contract.documentPrefix : contract.queryPrefix) + input
        if contract.lowercase { text = text.lowercased() }
        if contract.stripAccents {
            text = text.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        }
        let basic = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
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

    private func wordPieces(_ word: String) -> [String] {
        if vocabulary[word] != nil { return [word] }
        var result: [String] = [], start = word.startIndex
        while start < word.endIndex {
            var end = word.endIndex, match: String?
            while start < end {
                let raw = String(word[start..<end])
                let candidate = start == word.startIndex ? raw : "##" + raw
                if vocabulary[candidate] != nil { match = candidate; break }
                end = word.index(before: end)
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
    private let model: MLModel
    private let tokenizer: WordPieceTokenizer
    private let contract: SemanticModelArtifactContract

    init(model: MLModel, tokenizer: WordPieceTokenizer, contract: SemanticModelArtifactContract) {
        self.model = model; self.tokenizer = tokenizer; self.contract = contract
        modelIdentifier = contract.modelIdentifier; modelVersion = contract.modelVersion
        embeddingDimension = contract.embeddingDimension; tokenizerIdentifier = contract.tokenizerIdentifier
        preprocessingIdentifier = contract.preprocessingIdentifier
    }

    static func load(compiledModelURL: URL, contract: SemanticModelArtifactContract, vocabularyData: Data) async throws -> CoreMLSemanticEmbeddingProvider {
        try contract.validate()
        let tokenizer = try WordPieceTokenizer(data: vocabularyData, contract: contract)
        let model = try MLModel(contentsOf: compiledModelURL)
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
        let output = try model.prediction(from: input)
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
