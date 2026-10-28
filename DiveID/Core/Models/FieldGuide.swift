import Foundation
import Observation

/// A broad ocean region for the field guide, derived from the FAO major fishing area names
/// the catalogue records carry ("Western Central Pacific", "Mediterranean and Black Sea"…).
struct FieldGuideRegion: Hashable, Identifiable, Sendable {
    let id: String
    let title: String

    static let all = FieldGuideRegion(id: "all", title: "All regions")

    /// Ordered rules, most specific first: an "Antarctic Atlantic" area is the Southern Ocean.
    private static let rules: [(word: String, region: FieldGuideRegion)] = [
        ("antarctic", .init(id: "southern", title: "Southern Ocean")),
        ("arctic", .init(id: "arctic", title: "Arctic Ocean")),
        ("mediterranean", .init(id: "mediterranean", title: "Mediterranean and Black Sea")),
        ("pacific", .init(id: "pacific", title: "Pacific Ocean")),
        ("indian", .init(id: "indian", title: "Indian Ocean")),
        ("atlantic", .init(id: "atlantic", title: "Atlantic Ocean")),
    ]

    /// The ocean regions a record's distribution names. Its FAO areas come first; a record
    /// with none falls back to an ocean named in its regions ("atlantic", "indo-pacific").
    /// Empty means the distribution is unknown: such a species is listed under All regions only.
    static func regions(subregions: [String], regions: [String]) -> Set<FieldGuideRegion> {
        let fromAreas = Set(subregions.compactMap(region(named:)))
        if !fromAreas.isEmpty { return fromAreas }
        return Set(regions.compactMap { name in
            // Only the three oceans: a locality ("bahamas") or a pack name says nothing on its own.
            let word = name.lowercased()
            return rules.first { ["pacific", "indian", "atlantic"].contains($0.region.id) && word.contains($0.word) }?.region
        })
    }

    private static func region(named area: String) -> FieldGuideRegion? {
        let word = area.lowercased()
        return rules.first { word.contains($0.word) }?.region
    }

    static func ordered(_ regions: some Sequence<FieldGuideRegion>) -> [FieldGuideRegion] {
        let order = rules.map(\.region.id)
        return regions.sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
    }
}

/// An animal group, derived from the catalogue's categories: each category is a group,
/// except the invertebrate categories, which share one.
struct FieldGuideGroup: Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let count: Int
    /// A species with a photo, when the group has one, to show on the group's row.
    let representative: Species?

    static func groupID(forCategory category: String) -> String {
        CatalogueVocabulary.invertebrateCategories.contains(category) ? "invertebrates" : category
    }

    static func title(for id: String) -> String {
        switch id {
        case "fish": "Fish"
        case "seahorse": "Seahorses and pipefish"
        case "invertebrates": "Invertebrates"
        default: id.prefix(1).uppercased() + id.dropFirst() + "s"
        }
    }
}

/// One family's species within a group, in name order.
struct FieldGuideSection: Hashable, Identifiable, Sendable {
    var id: String { family }
    let family: String
    let species: [Species]
}

/// The whole catalogue, indexed once for browsing: groups, regions and families, and the
/// text a name filter matches. Building it decodes no images.
struct FieldGuideCatalogue: Sendable {
    struct Entry: Sendable {
        let species: Species
        let groupID: String
        let family: String
        let regions: Set<FieldGuideRegion>
        /// Common, scientific and other names, lowercased, for the name filter.
        let names: String
    }

    static let unknownFamily = "Family not recorded"
    let entries: [Entry]
    /// The regions the data supports, in a fixed order, with All regions first.
    let regions: [FieldGuideRegion]
    let unknownDistributionCount: Int

    init(profiles: [LocalSpeciesProfile], packContext: PackContext) {
        entries = profiles.map { profile in
            var species = profile.species
            species.packContext = packContext
            let family = profile.taxonomy?.family?.trimmingCharacters(in: .whitespaces)
            return Entry(
                species: species,
                groupID: FieldGuideGroup.groupID(forCategory: profile.categories.first ?? "fish"),
                family: family.flatMap { $0.isEmpty ? nil : $0 } ?? Self.unknownFamily,
                regions: FieldGuideRegion.regions(subregions: profile.subregions, regions: profile.regions),
                names: ([profile.commonName, profile.scientificName] + profile.aliases).joined(separator: " ").lowercased())
        }
        .sorted { $0.species.commonName.localizedCaseInsensitiveCompare($1.species.commonName) == .orderedAscending }
        regions = [.all] + FieldGuideRegion.ordered(Set(entries.flatMap(\.regions)))
        unknownDistributionCount = entries.filter(\.regions.isEmpty).count
    }

    /// "Never exclude on uncertainty": All regions lists everyone, including species whose
    /// distribution is unknown; a specific region lists the species recorded there.
    func entries(in region: FieldGuideRegion) -> [Entry] {
        region == .all ? entries : entries.filter { $0.regions.contains(region) }
    }

    /// The groups with species in this region, largest first, each with a representative photo.
    func groups(in region: FieldGuideRegion) -> [FieldGuideGroup] {
        let byGroup = Dictionary(grouping: entries(in: region), by: \.groupID)
        return byGroup.map { id, members in
            FieldGuideGroup(id: id, title: FieldGuideGroup.title(for: id), count: members.count,
                            representative: Self.representative(of: members))
        }
        .sorted { $0.count == $1.count ? $0.title < $1.title : $0.count > $1.count }
    }

    func count(in region: FieldGuideRegion) -> Int { entries(in: region).count }

    /// A group's species by family (unrecorded family last), filtered by name and photo.
    func sections(group: String, region: FieldGuideRegion, query: String = "", photosOnly: Bool = false) -> [FieldGuideSection] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let members = entries(in: region).filter { entry in
            entry.groupID == group
                && (!photosOnly || entry.species.hasPhoto)
                && words.allSatisfy(entry.names.contains)
        }
        return Dictionary(grouping: members, by: \.family)
            .map { FieldGuideSection(family: $0.key, species: $0.value.map(\.species)) }
            .sorted { lhs, rhs in
                if (lhs.family == Self.unknownFamily) != (rhs.family == Self.unknownFamily) { return rhs.family == Self.unknownFamily }
                return lhs.family.localizedCaseInsensitiveCompare(rhs.family) == .orderedAscending
            }
    }

    /// The photographed member of the group's largest family, first by name: deterministic,
    /// and typical of the group rather than of its alphabet.
    private static func representative(of members: [Entry]) -> Species? {
        let photographed = members.filter(\.species.hasPhoto)
        guard !photographed.isEmpty else { return nil }
        let family = Dictionary(grouping: photographed, by: \.family)
            .max { $0.value.count == $1.value.count ? $0.key > $1.key : $0.value.count < $1.value.count }?.key
        return photographed.first { $0.family == family }?.species
    }
}

/// Remembers the last region chosen in the field guide.
protocol FieldGuideRegionStore: Sendable {
    func load() -> String?
    func save(_ id: String)
}

struct UserDefaultsFieldGuideRegionStore: FieldGuideRegionStore, @unchecked Sendable {
    var defaults: UserDefaults = .standard
    var key = "fieldGuideRegion"
    func load() -> String? { defaults.string(forKey: key) }
    func save(_ id: String) { defaults.set(id, forKey: key) }
}

/// The field guide's state: the Global catalogue as this build exposes it (Release: approved
/// records only), the region filter, and the groups to show.
@MainActor @Observable
final class FieldGuideViewModel {
    private(set) var catalogue: FieldGuideCatalogue?
    private(set) var metadata: OfflineIdentificationPackMetadata?
    private(set) var isLoading = false
    var errorMessage: String?
    var region: FieldGuideRegion = .all {
        didSet { if region != oldValue { regionStore.save(region.id) } }
    }
    private let catalog: any MarineSpeciesCatalogRepository
    private let regionStore: any FieldGuideRegionStore

    init(catalog: any MarineSpeciesCatalogRepository, regionStore: any FieldGuideRegionStore = UserDefaultsFieldGuideRegionStore()) {
        self.catalog = catalog
        self.regionStore = regionStore
    }

    var groups: [FieldGuideGroup] { catalogue?.groups(in: region) ?? [] }
    var regionCount: Int { catalogue?.count(in: region) ?? 0 }

    /// The note under a specific region: species with unknown distribution aren't excluded,
    /// they're listed under All regions.
    var unknownDistributionNote: String? {
        guard let catalogue, region != .all, catalogue.unknownDistributionCount > 0 else { return nil }
        let count = catalogue.unknownDistributionCount
        return "\(count) \(count == 1 ? "species has" : "species have") no recorded distribution and \(count == 1 ? "is" : "are") listed only under All regions."
    }

    func load() async {
        guard catalogue == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            guard let metadata = try await catalog.availablePacks().first(where: { $0.id == .global }) else {
                errorMessage = "The field guide's catalogue isn't available in this build."
                return
            }
            let pack = try await catalog.loadPack(id: .global)
            let context = PackContext(packID: metadata.id, displayName: metadata.displayName, packVersion: metadata.packVersion)
            let profiles = pack.profiles
            // Off the main thread: indexing thousands of records must not block scrolling.
            let catalogue = await Task.detached(priority: .userInitiated) {
                FieldGuideCatalogue(profiles: profiles, packContext: context)
            }.value
            self.metadata = metadata
            self.catalogue = catalogue
            let saved = regionStore.load()
            region = catalogue.regions.first { $0.id == saved } ?? .all
            errorMessage = nil
        } catch {
            errorMessage = "The field guide could not be loaded. Please try again."
        }
    }
}
