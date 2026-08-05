import Foundation

protocol SelectedDiveRegionRepository: Sendable {
    func selectedRegion() async -> OfflineIdentificationPackID
    func setSelectedRegion(_ id: OfflineIdentificationPackID) async
}

actor UserDefaultsSelectedDiveRegionRepository: SelectedDiveRegionRepository {
    private let defaults: UserDefaults
    private let key: String
    init(defaults: UserDefaults = .standard, key: String = "selectedDiveRegion") { self.defaults = defaults; self.key = key }
    func selectedRegion() async -> OfflineIdentificationPackID {
        guard let raw = defaults.string(forKey: key), let id = OfflineIdentificationPackID(rawValue: raw) else { return .caribbean }
        return id
    }
    func setSelectedRegion(_ id: OfflineIdentificationPackID) async { defaults.set(id.rawValue, forKey: key) }
}
