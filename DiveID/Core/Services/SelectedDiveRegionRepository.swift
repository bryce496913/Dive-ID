import Foundation

protocol SelectedDiveRegionRepository: Sendable {
    func selectedRegion() async -> OfflineIdentificationPackID
    func setSelectedRegion(_ id: OfflineIdentificationPackID) async
}

/// The dive region a new install starts with. It stays regional while the Global pack
/// fails its evaluation gates (Docs/GlobalPackEvaluation.md); a stored choice, Global
/// included, is always kept.
enum DefaultDiveRegion {
    static let forNewInstalls: OfflineIdentificationPackID = .caribbean
}

actor UserDefaultsSelectedDiveRegionRepository: SelectedDiveRegionRepository {
    private let defaults: UserDefaults
    private let key: String
    init(defaults: UserDefaults = .standard, key: String = "selectedDiveRegion") { self.defaults = defaults; self.key = key }
    func selectedRegion() async -> OfflineIdentificationPackID {
        guard let raw = defaults.string(forKey: key) else { return DefaultDiveRegion.forNewInstalls }
        return OfflineIdentificationPackID(rawValue: raw)
    }
    func setSelectedRegion(_ id: OfflineIdentificationPackID) async { defaults.set(id.rawValue, forKey: key) }
}
