import Foundation

/// Where Dive Log and feedback exports are written for the share sheet. Each new export
/// clears the folder first, so old export files don't pile up in tmp.
enum ExportFiles {
    static func directory(base: URL = FileManager.default.temporaryDirectory) -> URL {
        let url = base.appendingPathComponent("DiveID-Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Removes the earlier exports in `directory`; failures are ignored (iOS clears tmp anyway).
    static func removeAll(in directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("DiveID-") { try? FileManager.default.removeItem(at: file) }
    }
}
