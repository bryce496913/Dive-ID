import Foundation
import ImageIO

actor BundleMarineSpeciesCatalogRepository: MarineSpeciesCatalogRepository {
    private let bundle: Bundle
    private var cachedPacks: [OfflineIdentificationPackID: OfflineIdentificationPack] = [:]
    private let root = "IdentificationPacks/Caribbean"

    init(bundle: Bundle = .main, resourceName: String = "MarineSpeciesCatalog") { self.bundle = bundle }

    func availablePacks() async throws -> [OfflineIdentificationPackMetadata] { [try loadManifest()] }

    func loadPack(id: OfflineIdentificationPackID) async throws -> OfflineIdentificationPack {
        if let cached = cachedPacks[id] { return cached }
        guard id == .caribbean else { throw LocalCatalogError.unsupportedPack }
        let metadata = try loadManifest()
        guard metadata.id == id else { throw LocalCatalogError.unsupportedPack }
        guard let url = resourceURL(path: root + "/" + metadata.speciesResourceName, ext: "json") else { throw LocalCatalogError.resourceMissing }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let profiles = try decoder.decode([LocalSpeciesProfile].self, from: data)
        try Self.validate(pack: OfflineIdentificationPack(metadata: metadata, profiles: profiles), bundle: bundle)
        let sorted = profiles.sorted { $0.commonName.localizedStandardCompare($1.commonName) == .orderedAscending }
        let pack = OfflineIdentificationPack(metadata: metadata, profiles: sorted)
        cachedPacks[id] = pack
        return pack
    }

    private func loadManifest() throws -> OfflineIdentificationPackMetadata {
        guard let url = resourceURL(path: root + "/PackManifest", ext: "json") else { throw LocalCatalogError.resourceMissing }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OfflineIdentificationPackMetadata.self, from: Data(contentsOf: url))
    }

    private func resourceURL(path: String, ext: String) -> URL? {
        bundle.url(forResource: path, withExtension: ext) ?? URL(fileURLWithPath: "DiveID/Resources/").appendingPathComponent(path).appendingPathExtension(ext)
            .standardizedFileURL
            .absoluteURL
            .existing
    }

    static func validate(pack: OfflineIdentificationPack, bundle: Bundle = .main) throws {
        let m = pack.metadata; let profiles = pack.profiles
        guard m.schemaVersion == 1 else { throw LocalCatalogError.unsupportedSchemaVersion }
        guard m.packVersion > 0 else { throw LocalCatalogError.invalidPackVersion }
        guard !m.displayName.isEmpty, !m.geographicScope.isEmpty else { throw LocalCatalogError.invalidData }
        guard m.speciesCount == profiles.count else { throw LocalCatalogError.countMismatch(expected: m.speciesCount, actual: profiles.count) }
        if m.id == .caribbean, profiles.count != 78 { throw LocalCatalogError.countMismatch(expected: 78, actual: profiles.count) }
        try validate(profiles, metadata: m, bundle: bundle)
    }

    static func validate(_ profiles: [LocalSpeciesProfile], metadata: OfflineIdentificationPackMetadata? = nil, bundle: Bundle = .main) throws {
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
            try validateRange(min: p.minimumSizeCentimeters, max: p.maximumSizeCentimeters); try validateRange(min: p.minimumDepthMeters, max: p.maximumDepthMeters)
            try validate(p.categories, allowed: LocalObservationVocabulary.categories); try validate(p.colors, allowed: LocalObservationVocabulary.colors); try validate(p.markings, allowed: LocalObservationVocabulary.markings); try validate(p.bodyShapes, allowed: LocalObservationVocabulary.bodyShapes); try validate(p.habitats, allowed: LocalObservationVocabulary.habitats); try validate(p.regions, allowed: LocalObservationVocabulary.regions); try validate(p.behaviors, allowed: LocalObservationVocabulary.behaviors)
            let own = Set([normalizedIdentity(p.commonName), normalizedIdentity(p.scientificName)])
            for a in p.aliases.map(normalizedIdentity) where !a.isEmpty && canonical.contains(a) && !own.contains(a) { throw LocalCatalogError.aliasCollidesWithCanonicalIdentity }
            var variantIDs = Set<String>(); for v in p.appearanceVariants { guard variantIDs.insert(v.id).inserted else { throw LocalCatalogError.invalidData }; try validateRange(min: v.minimumSizeCentimeters, max: v.maximumSizeCentimeters) }
            for c in p.similarSpecies { guard c.speciesID != p.id else { throw LocalCatalogError.selfSimilarSpeciesReference }; guard ids.contains(c.speciesID), !c.distinguishingText.isEmpty else { throw LocalCatalogError.invalidSimilarSpeciesReference } }
            guard let image = p.bundledImage else { throw LocalCatalogError.missingImage(p.id) }
            guard images.insert(image.fileName).inserted else { throw LocalCatalogError.duplicateImageFilename }
            guard !image.alternativeText.isEmpty, !image.creatorName.isEmpty, !image.sourceName.isEmpty, !image.licenseURL.isEmpty else { throw LocalCatalogError.emptyImageAttribution }
            guard ["CC0", "Public Domain", "CC BY 4.0", "CC BY"].contains(image.licenseName) else { throw LocalCatalogError.unsupportedImageLicense(image.licenseName) }
        }
    }
    private static func normalizedIdentity(_ v: String) -> String { v.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private static func validateRange(min: Double?, max: Double?) throws { if let min, min < 0 { throw LocalCatalogError.negativeMeasurement }; if let max, max < 0 { throw LocalCatalogError.negativeMeasurement }; if let min, let max, min > max { throw LocalCatalogError.invalidMeasurementRange } }
    private static func validate(_ values: [String], allowed: Set<String>) throws { for v in values where !allowed.contains(v.lowercased()) { throw LocalCatalogError.unknownControlledVocabularyValue(v) } }
}

private extension URL { var existing: URL? { FileManager.default.fileExists(atPath: path) ? self : nil } }
