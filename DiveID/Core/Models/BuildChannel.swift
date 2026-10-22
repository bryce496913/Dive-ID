import Foundation

/// The kind of build that is running, decided at compile time.
///
/// - `debug`: the `DEBUG` condition (Xcode Debug, SwiftPM debug).
/// - `internal`: the Xcode **Internal** configuration. It is optimized like Release and
///   never defines `DEBUG`, but it defines `DIVEID_INTERNAL` and opens the development
///   catalogue, so draft packs can be measured on an iPhone at Release-like speed.
///   It installs under its own bundle identifier and is never a distribution build.
/// - `release`: everything else. Release exposes publication-eligible records only.
///
/// `DEBUG` wins if both conditions are set, so a misconfigured build can never turn a
/// Debug build into something that looks like Release.
enum BuildChannel: String, Sendable, CaseIterable {
    case debug
    case `internal`
    case release

    static let current: BuildChannel = {
#if DEBUG
        .debug
#elseif DIVEID_INTERNAL
        .internal
#else
        .release
#endif
    }()

    /// Only Release is limited to human-approved records.
    var catalogueAccess: BundleMarineSpeciesCatalogRepository.CatalogueAccess {
        self == .release ? .publication : .experimentalDevelopment
    }

    /// Catalogue diagnostic codes (for example `CATALOG_DECODE_FAILED`) are shown in
    /// error messages on test builds, never in Release.
    var showsDiagnosticCodes: Bool { self != .release }
}
