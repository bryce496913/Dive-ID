import Foundation

/// Credits for catalogue content licensed CC BY-NC 4.0 by FishBase and SeaLifeBase.
/// The licence requires credit to the creators, a licence notice and link, a link to
/// each record's source page and a statement that Dive ID modified the content.
struct CatalogueCredit: Hashable, Sendable {
    let name: String
    let citation: String
    let release: String
    let websiteURL: String
}

/// A species photo's credit for Data Sources and Credits.
struct PhotoCredit: Hashable, Sendable {
    let commonName: String
    let scientificName: String
    let image: BundledSpeciesImage
}

enum CatalogueAttribution {
    /// The pinned bulk-data release (Tools/FishBaseIntake/release_manifest.json).
    static let release = "v26.06"
    static let licenseName = "CC BY-NC 4.0"
    static let licenseURL = "https://creativecommons.org/licenses/by-nc/4.0/"

    static let credits: [CatalogueCredit] = [
        CatalogueCredit(name: "FishBase",
                        citation: "Froese, R. and D. Pauly. Editors. 2026. FishBase. World Wide Web electronic publication. www.fishbase.org.",
                        release: release, websiteURL: "https://www.fishbase.org"),
        CatalogueCredit(name: "SeaLifeBase",
                        citation: "Palomares, M.L.D. and D. Pauly. Editors. 2026. SeaLifeBase. World Wide Web electronic publication. www.sealifebase.org.",
                        release: release, websiteURL: "https://www.sealifebase.org")
    ]

    static let licenseNotice = "Species text and data from FishBase and SeaLifeBase are licensed under \(licenseName) and are used non-commercially."
    static let modificationNotice = "Dive ID changed this content: facts were summarised in new wording, mapped to Dive ID's descriptive vocabulary and ranges, and grouped into dive regions. FishBase and SeaLifeBase do not endorse Dive ID."
    static let perRecordNotice = "Each species page links to its source record and cites its main reference."

    /// One line per source of a species, citing its reference and licence, with the
    /// source page link the licence asks for.
    static func sourceLines(for sources: [SpeciesDataSourceReference]) -> [(text: String, url: URL?)] {
        sources.map { source in
            var parts = [source.sourceName]
            if let reference = source.citationReference, !reference.isEmpty { parts.append("Reference: \(reference)") }
            if let license = source.sourceLicense, !license.isEmpty { parts.append(license) }
            return (parts.joined(separator: " — "), URL(string: source.sourceURL))
        }
    }

    static let photoNotice = "Species photos are by the photographers named, from iNaturalist observations, under the licence shown with each. Dive ID resized them; the photographers do not endorse Dive ID."

    /// One credit per bundled photo across the given packs, by species name. A region drawn
    /// from Global repeats Global's records, so each photo is listed once. Packs exposed in a
    /// Release build hold only approved records, and only approved photos are bundled.
    static func photoCredits(in packs: [OfflineIdentificationPack]) -> [PhotoCredit] {
        var seen = Set<String>()
        var credits: [PhotoCredit] = []
        for profile in packs.flatMap(\.profiles) {
            guard let image = profile.bundledImage, image.isPhoto, seen.insert(image.fileName).inserted else { continue }
            credits.append(PhotoCredit(commonName: profile.commonName, scientificName: profile.scientificName, image: image))
        }
        return credits.sorted {
            let order = $0.commonName.localizedStandardCompare($1.commonName)
            return order == .orderedSame ? $0.image.fileName < $1.image.fileName : order == .orderedAscending
        }
    }
}
