import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

actor BundleMarineSpeciesCatalogRepository: MarineSpeciesCatalogRepository {
    enum ResourceResolutionMode: Sendable {
        case bundleOnly
        case bundleThenDevelopmentSource
    }

    private let bundle: Bundle
    private let registry: RegionCatalogRegistry
    private let resourceResolutionMode: ResourceResolutionMode
    private let developmentSourceRoot: URL
    private var cachedPacks: [OfflineIdentificationPackID: OfflineIdentificationPack] = [:]
    init(
        bundle: Bundle = .main,
        registry: RegionCatalogRegistry = .bundled,
        resourceResolutionMode: ResourceResolutionMode = .bundleOnly,
        developmentSourceRoot: URL = URL(fileURLWithPath: "DiveID/Resources", isDirectory: true)
    ) {
        self.bundle = bundle
        self.registry = registry
        self.resourceResolutionMode = resourceResolutionMode
        self.developmentSourceRoot = developmentSourceRoot
    }

    func availablePacks() async throws -> [OfflineIdentificationPackMetadata] {
        try registry.definitions.map(loadManifest)
    }

    func loadPack(id: OfflineIdentificationPackID) async throws -> OfflineIdentificationPack {
        if let cached = cachedPacks[id] { return cached }
        guard let definition = registry.definition(for: id) else {
            throw failure(id, .unsupportedPack, .unsupportedPack, nil, .manifest)
        }
        let metadata = try loadManifest(definition)
        guard metadata.id == id else {
            throw failure(id, .unsupportedPack, .unsupportedPack, manifestResource(definition), .validation)
        }
        let root = "IdentificationPacks/" + definition.resourceDirectory
        let speciesResource = root + "/" + metadata.speciesResourceName + ".json"
        guard let url = resourceURL(path: root + "/" + metadata.speciesResourceName, ext: "json") else {
            throw failure(id, .speciesResourceMissing, .resourceMissing, speciesResource, .speciesResource)
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw failure(id, .speciesResourceMissing, .unreadableData, speciesResource, .speciesResource) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let profiles: [LocalSpeciesProfile]
        do { profiles = try decoder.decode([LocalSpeciesProfile].self, from: data) }
        catch { throw failure(id, .decodeFailed, .invalidData, speciesResource, .decoding) }
        do {
            try Self.validate(
                pack: OfflineIdentificationPack(metadata: metadata, profiles: profiles),
                bundle: bundle,
                resourceDirectory: definition.resourceDirectory,
                resourceResolver: resourceURL(path:ext:)
            )
        } catch let error as LocalCatalogError {
            let context = validationContext(error: error, profiles: profiles, metadata: metadata, directory: definition.resourceDirectory)
            throw failure(id, context.code, error, context.resource ?? speciesResource, context.phase)
        }
        let sorted = profiles.sorted { $0.commonName.localizedStandardCompare($1.commonName) == .orderedAscending }
        let pack = OfflineIdentificationPack(metadata: metadata, profiles: sorted)
        cachedPacks[id] = pack
        return pack
    }

    private func loadManifest(_ definition: RegionCatalogDefinition) throws -> OfflineIdentificationPackMetadata {
        let root = "IdentificationPacks/" + definition.resourceDirectory
        let resource = manifestResource(definition)
        guard let url = resourceURL(path: root + "/" + definition.manifestResourceName, ext: "json") else {
            throw failure(definition.id, .manifestMissing, .resourceMissing, resource, .manifest)
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw failure(definition.id, .manifestMissing, .unreadableData, resource, .manifest) }
        do { return try decoder.decode(OfflineIdentificationPackMetadata.self, from: data) }
        catch { throw failure(definition.id, .decodeFailed, .invalidData, resource, .decoding) }
    }

    private func resourceURL(path: String, ext: String) -> URL? {
        if let bundled = bundle.url(forResource: path, withExtension: ext) { return bundled }
        guard resourceResolutionMode == .bundleThenDevelopmentSource else { return nil }
        return developmentSourceRoot.appendingPathComponent(path).appendingPathExtension(ext).standardizedFileURL.existing
    }

    private func manifestResource(_ definition: RegionCatalogDefinition) -> String {
        "IdentificationPacks/\(definition.resourceDirectory)/\(definition.manifestResourceName).json"
    }

    private func failure(_ packID: OfflineIdentificationPackID, _ code: CatalogueDiagnosticCode, _ error: LocalCatalogError?, _ resource: String?, _ phase: CatalogueLoadPhase) -> CatalogueLoadFailure {
        CatalogueLoadFailure(packID: packID, code: code, catalogError: error, resource: resource, phase: phase)
    }

    private func validationContext(error: LocalCatalogError, profiles: [LocalSpeciesProfile], metadata: OfflineIdentificationPackMetadata, directory: String) -> (code: CatalogueDiagnosticCode, resource: String?, phase: CatalogueLoadPhase) {
        switch error {
        case .countMismatch: return (.countMismatch, nil, .validation)
        case .unknownControlledVocabularyValue: return (.vocabularyInvalid, nil, .validation)
        case .missingImage(let id): return (.artworkMissing, artworkResource(id: id, profiles: profiles, metadata: metadata, directory: directory), .artworkValidation)
        case .invalidImage(let id), .imageTooLarge(let id): return (.artworkInvalid, artworkResource(id: id, profiles: profiles, metadata: metadata, directory: directory), .artworkValidation)
        case .emptyImageAttribution, .unsupportedImageLicense, .duplicateImageFilename:
            return (.artworkInvalid, nil, .artworkValidation)
        case .unsupportedSchemaVersion: return (.unsupportedPack, nil, .validation)
        default: return (.validationFailed, nil, .validation)
        }
    }

    private func artworkResource(id: UUID, profiles: [LocalSpeciesProfile], metadata: OfflineIdentificationPackMetadata, directory: String) -> String? {
        guard let fileName = profiles.first(where: { $0.id == id })?.bundledImage?.fileName else { return nil }
        return "IdentificationPacks/\(directory)/\(metadata.imageSubdirectory)/\(fileName)"
    }

    static func validate(pack: OfflineIdentificationPack, bundle: Bundle = .main, resourceDirectory: String? = nil, resourceResolver: ((String, String) -> URL?)? = nil) throws {
        let m = pack.metadata; let profiles = pack.profiles
        guard m.schemaVersion == 1 else { throw LocalCatalogError.unsupportedSchemaVersion }
        guard m.packVersion > 0 else { throw LocalCatalogError.invalidPackVersion }
        guard !m.displayName.isEmpty, !m.geographicScope.isEmpty else { throw LocalCatalogError.invalidData }
        guard m.speciesCount == profiles.count else { throw LocalCatalogError.countMismatch(expected: m.speciesCount, actual: profiles.count) }
        let directory = resourceDirectory ?? RegionCatalogRegistry.bundled.definition(for: m.id)?.resourceDirectory ?? m.id.rawValue
        try validate(profiles, metadata: m, bundle: bundle, resourceDirectory: directory, resourceResolver: resourceResolver)
    }

    static func validate(_ profiles: [LocalSpeciesProfile], metadata: OfflineIdentificationPackMetadata? = nil, bundle: Bundle = .main, resourceDirectory: String? = nil, resourceResolver: ((String, String) -> URL?)? = nil) throws {
        var ids = Set<UUID>(), sci = Set<String>(), names = Set<String>(), canonical = Set<String>(), images = Set<String>()
        for p in profiles {
            guard ids.insert(p.id).inserted else { throw LocalCatalogError.duplicateIdentifier }
            let cn = normalizedIdentity(p.commonName), sn = normalizedIdentity(p.scientificName)
            guard !cn.isEmpty else { throw LocalCatalogError.emptyCommonName }; guard !sn.isEmpty else { throw LocalCatalogError.emptyScientificName }
            guard sci.insert(sn).inserted else { throw LocalCatalogError.duplicateScientificName }
            guard names.insert(cn).inserted else { throw LocalCatalogError.duplicateCommonName }
            canonical.formUnion([cn,sn])
        }
        for p in profiles {
            guard !p.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalCatalogError.emptySummary }
            guard !p.distinguishingFeatures.isEmpty else { throw LocalCatalogError.emptyDistinguishingFeatures }
            guard !p.typicalHabitat.isEmpty else { throw LocalCatalogError.emptyHabitatDescription }
            guard !p.geographicRange.isEmpty else { throw LocalCatalogError.emptyGeographicRange }
            guard !p.dataSources.isEmpty else { throw LocalCatalogError.missingDataSource }
            if p.review?.status == .verified {
                guard let reviewer = p.review?.verifiedBy, !reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      p.review?.reviewDate != nil,
                      let notes = p.review?.reviewerNotes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw LocalCatalogError.unverifiedRecord }
            }
            try validateRange(min: p.minimumSizeCentimeters, max: p.maximumSizeCentimeters); try validateRange(min: p.minimumDepthMeters, max: p.maximumDepthMeters)
            try validate(p.categories, allowed: CatalogueVocabulary.categories); try validate(p.colors, allowed: CatalogueVocabulary.colors); try validate(p.markings, allowed: CatalogueVocabulary.markings); try validate(p.bodyShapes, allowed: CatalogueVocabulary.bodyShapes); try validate(p.habitats, allowed: CatalogueVocabulary.habitats); try validate(p.regions, allowed: CatalogueVocabulary.regions); try validate(p.behaviors, allowed: CatalogueVocabulary.behaviors)
            let own = Set([normalizedIdentity(p.commonName), normalizedIdentity(p.scientificName)])
            for a in p.aliases.map(normalizedIdentity) where !a.isEmpty && canonical.contains(a) && !own.contains(a) { throw LocalCatalogError.aliasCollidesWithCanonicalIdentity }
            var variantIDs = Set<String>()
            for v in p.appearanceVariants {
                guard variantIDs.insert(v.id).inserted else { throw LocalCatalogError.invalidData }
                try validateRange(min: v.minimumSizeCentimeters, max: v.maximumSizeCentimeters)
                try validate(v.colors, allowed: CatalogueVocabulary.colors)
                try validate(v.markings, allowed: CatalogueVocabulary.markings)
                try validate(v.bodyShapes, allowed: CatalogueVocabulary.bodyShapes)
            }
            for c in p.similarSpecies { guard c.speciesID != p.id else { throw LocalCatalogError.selfSimilarSpeciesReference }; guard ids.contains(c.speciesID), !c.distinguishingText.isEmpty else { throw LocalCatalogError.invalidSimilarSpeciesReference } }
            if let image = p.bundledImage {
                guard images.insert(image.fileName).inserted else { throw LocalCatalogError.duplicateImageFilename }
                guard isValidImageFileName(image.fileName) else { throw LocalCatalogError.invalidImage(p.id) }
                guard !image.alternativeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !image.creatorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !image.sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      isWebURL(image.sourceURL), isWebURL(image.licenseURL)
                else { throw LocalCatalogError.emptyImageAttribution }
                guard ["CC0", "Public Domain", "CC BY 4.0", "CC BY"].contains(image.licenseName) else { throw LocalCatalogError.unsupportedImageLicense(image.licenseName) }
                if let metadata {
                    try validateImageFile(image, speciesID: p.id, metadata: metadata, bundle: bundle, resourceDirectory: resourceDirectory ?? metadata.id.rawValue, resourceResolver: resourceResolver)
                }
            }
        }
    }
    private static let maximumImageByteCount = 5_000_000
    private static let maximumImageDimension = 4_096

    private static func validateImageFile(_ image: BundledSpeciesImage, speciesID: UUID, metadata: OfflineIdentificationPackMetadata, bundle: Bundle, resourceDirectory: String, resourceResolver: ((String, String) -> URL?)?) throws {
        let path = "IdentificationPacks/\(resourceDirectory)/\(metadata.imageSubdirectory)/\(image.fileName)"
        guard let url = resourceResolver?(path, "") ?? bundle.url(forResource: path, withExtension: nil)
        else { throw LocalCatalogError.missingImage(speciesID) }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { throw LocalCatalogError.invalidImage(speciesID) }
        guard data.count <= maximumImageByteCount else { throw LocalCatalogError.imageTooLarge(speciesID) }

        if image.fileName.lowercased().hasSuffix(".svg") {
            guard let source = String(data: data, encoding: .utf8),
                  source.range(of: #"<svg\b"#, options: .regularExpression) != nil,
                  let dimensions = svgDimensions(source)
            else { throw LocalCatalogError.invalidImage(speciesID) }
            guard dimensions.width <= maximumImageDimension, dimensions.height <= maximumImageDimension
            else { throw LocalCatalogError.imageTooLarge(speciesID) }
        } else {
#if canImport(ImageIO)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int
            else { throw LocalCatalogError.invalidImage(speciesID) }
            guard width <= maximumImageDimension, height <= maximumImageDimension
            else { throw LocalCatalogError.imageTooLarge(speciesID) }
#else
            throw LocalCatalogError.invalidImage(speciesID)
#endif
        }
    }

    private static func svgDimensions(_ source: String) -> (width: Int, height: Int)? {
        let pattern = #"viewBox\s*=\s*[\"']\s*[-+]?\d+(?:\.\d+)?[\s,]+[-+]?\d+(?:\.\d+)?[\s,]+(\d+(?:\.\d+)?)[\s,]+(\d+(?:\.\d+)?)[\"']"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let widthRange = Range(match.range(at: 1), in: source),
              let heightRange = Range(match.range(at: 2), in: source),
              let width = Double(source[widthRange]), let height = Double(source[heightRange]),
              width > 0, height > 0
        else { return nil }
        return (Int(width.rounded(.up)), Int(height.rounded(.up)))
    }

    private static func isValidImageFileName(_ value: String) -> Bool {
        let url = URL(fileURLWithPath: value)
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && url.lastPathComponent == value
            && ["svg", "png", "jpg", "jpeg"].contains(url.pathExtension.lowercased())
    }

    private static func isWebURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value), let scheme = components.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme) && components.host != nil
    }
    private static func normalizedIdentity(_ v: String) -> String { v.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private static func validateRange(min: Double?, max: Double?) throws { if let min, min < 0 { throw LocalCatalogError.negativeMeasurement }; if let max, max < 0 { throw LocalCatalogError.negativeMeasurement }; if let min, let max, min > max { throw LocalCatalogError.invalidMeasurementRange } }
    private static func validate(_ values: [String], allowed: Set<String>) throws { for v in values where !allowed.contains(v.lowercased()) { throw LocalCatalogError.unknownControlledVocabularyValue(v) } }
}

private extension URL { var existing: URL? { FileManager.default.fileExists(atPath: path) ? self : nil } }
