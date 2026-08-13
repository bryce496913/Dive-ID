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
        guard let raw = defaults.string(forKey: key) else { return .caribbean }
        return OfflineIdentificationPackID(rawValue: raw)
    }
    func setSelectedRegion(_ id: OfflineIdentificationPackID) async { defaults.set(id.rawValue, forKey: key) }
}
