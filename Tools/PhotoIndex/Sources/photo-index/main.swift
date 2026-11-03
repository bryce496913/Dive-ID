import DiveID
import Foundation
import PhotoIndexBuilder

// Builds DiveID/Resources/IdentificationPacks/<pack>/PhotoIndex.bin (bundled) and
// Data/PhotoIndex/<pack>.json (its sidecar) from the pack's approved bundled photos.
// Run from the repository root:
//   swift run -c release photo-index [Global]
let packName = CommandLine.arguments.dropFirst().first ?? "Global"
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let packDirectory = root.appendingPathComponent("DiveID/Resources/IdentificationPacks/\(packName)")
let policy = root.appendingPathComponent("Tools/SpeciesPhotos/photo_policy.json")

guard VisionFeaturePrint.isAvailable else {
    FileHandle.standardError.write(Data("photo-index needs macOS (Apple Vision).\n".utf8))
    exit(1)
}
do {
    let start = Date()
    let builder = try PhotoIndexBuilder(packDirectory: packDirectory, packID: packName.lowercased(), policyURL: policy) { url in
        try VisionFeaturePrint.vector(imageData: Data(contentsOf: url))
    }
    let (index, sidecar) = try builder.build()
    try PhotoIndexBuilder.write(index, sidecar, index: packDirectory.appendingPathComponent("PhotoIndex.bin"),
                                sidecar: root.appendingPathComponent("Data/PhotoIndex/\(packName).json"))
    let bytes = index.encoded().count
    print("Indexed \(index.entries.count) photos of \(index.coveredSpeciesIDs.count) species, \(index.dimension) dimensions, "
          + "request revision \(index.requestRevision), \(bytes.formatted()) bytes, in \(String(format: "%.1f", Date().timeIntervalSince(start))) s.")
    print("Catalogue content version: \(index.catalogueContentVersion)")
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
