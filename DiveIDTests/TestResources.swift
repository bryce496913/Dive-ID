import Foundation

enum TestResources {
    /// Production resources belong to the hosted app in Xcode. SwiftPM's core target
    /// intentionally has no resources and uses the repository checkout fallback.
    static var productionBundle: Bundle {
#if SWIFT_PACKAGE
        Bundle(for: BundleToken.self)
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

    private final class BundleToken {}
}
