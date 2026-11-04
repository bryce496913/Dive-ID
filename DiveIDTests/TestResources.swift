import Foundation
@testable import DiveID

enum TestResources {
    /// Production resources belong to the hosted app in Xcode and to the library's
    /// explicitly declared resource bundle in SwiftPM.
    static var productionBundle: Bundle {
#if SWIFT_PACKAGE
        BundleMarineSpeciesCatalogRepository.swiftPackageResourceBundle
#else
        .main
#endif
    }

    static func fixture(named name: String, subdirectory: String? = nil) throws -> URL {
        let testBundle: Bundle
#if SWIFT_PACKAGE
        testBundle = .module
#else
        testBundle = Bundle(for: BundleToken.self)
#endif
        let nestedDirectory = ["Fixtures", subdirectory].compactMap { $0 }.joined(separator: "/")
        let directories: [String?] = [subdirectory, nestedDirectory]
        for directory in directories {
            if let url = testBundle.url(forResource: name, withExtension: "json", subdirectory: directory) {
                return url
            }
        }

        let fixtureRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
        let sourceURL = subdirectory.map { fixtureRoot.appendingPathComponent($0, isDirectory: true) } ?? fixtureRoot
        let url = sourceURL.appendingPathComponent(name).appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return url
    }

    /// The directory holding `IdentificationPacks/` test packs: the retired Caribbean and
    /// Tropical Pacific packs (never in the app) and synthetic fixtures such as PartialApproval.
    static var fixturePacksRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)
    }

    /// One fixture pack's directory, e.g. "Caribbean".
    static func fixturePack(_ directory: String) -> URL {
        fixturePacksRoot.appendingPathComponent("IdentificationPacks/\(directory)", isDirectory: true)
    }

    /// A file inside a fixture pack, e.g. ("Caribbean", "Creatures.json"), or nil when missing.
    static func fixturePackFile(_ directory: String, _ path: String) -> URL? {
        let url = fixturePack(directory).appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The app's packs from the production bundle, falling back to the fixture packs for the
    /// retired Caribbean and Tropical Pacific regions, whose records the app no longer ships.
    /// `resourceResolutionMode` is accepted for call-site compatibility; the fallback always
    /// applies, and it finds nothing but the fixture packs.
    static func catalogRepository(registry: RegionCatalogRegistry = .bundled,
                                  resourceResolutionMode: BundleMarineSpeciesCatalogRepository.ResourceResolutionMode = .bundleOnly,
                                  access: BundleMarineSpeciesCatalogRepository.CatalogueAccess = BuildChannel.current.catalogueAccess) -> BundleMarineSpeciesCatalogRepository {
        BundleMarineSpeciesCatalogRepository(bundle: productionBundle, registry: registry, resourceResolutionMode: .bundleThenDevelopmentSource,
                                             developmentSourceRoot: fixturePacksRoot, access: access)
    }

    private final class BundleToken {}
}
