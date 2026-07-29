import Foundation

enum MockSpecies {
    static let all: [Species] = {
        let rows: [(String, String, String, [String], String, String)] = [
            ("Yellow Tang", "Zebrasoma flavescens", "A laterally compressed reef fish recognizable by its vivid yellow body.", ["Bright yellow body", "Disk-shaped profile", "Pointed snout"], "Shallow coral reefs and lagoons", "Central and western Pacific"),
            ("Moorish Idol", "Zanclus cornutus", "A distinctive reef fish with bold bands and a long dorsal filament.", ["Black, white, and yellow bands", "Long dorsal streamer"], "Clear tropical reefs", "Indo-Pacific"),
            ("Blue Tang", "Acanthurus coeruleus", "An oval-bodied surgeonfish whose adult coloration is deep blue.", ["Blue body", "Yellow-edged tail spine"], "Coral reefs", "Western Atlantic"),
            ("Threadfin Butterflyfish", "Chaetodon auriga", "A patterned butterflyfish commonly seen in pairs on reefs.", ["Diagonal dark markings", "Eye stripe", "Dorsal filament"], "Lagoons and seaward reefs", "Indo-Pacific"),
            ("Stoplight Parrotfish", "Sparisoma viride", "A robust grazing fish with color that varies by life phase.", ["Beak-like dental plates", "Angular forehead"], "Coral reefs and seagrass", "Western Atlantic"),
            ("Red Lionfish", "Pterois volitans", "A striped fish with conspicuous fan-like fins and long fin rays.", ["Red and white bands", "Broad pectoral fins"], "Reefs and rocky areas", "Native Indo-Pacific"),
            ("Ocellaris Clownfish", "Amphiprion ocellaris", "A small orange reef fish associated with host anemones.", ["Three white bars", "Black-edged fins"], "Sheltered reefs with anemones", "Eastern Indian Ocean and western Pacific"),
            ("Great Barracuda", "Sphyraena barracuda", "A long, streamlined predator often seen cruising near reefs.", ["Elongated silver body", "Large jaw", "Dark body spots"], "Reefs, channels, and open coastal water", "Tropical and subtropical seas"),
            ("Green Sea Turtle", "Chelonia mydas", "A large marine turtle with a smooth, rounded shell.", ["Oval shell", "Small rounded head", "Paddle-like flippers"], "Seagrass beds, lagoons, and coastal water", "Tropical and subtropical oceans"),
            ("Spotted Eagle Ray", "Aetobatus narinari", "A broad ray with pale spots and a long whip-like tail.", ["Dark back with white spots", "Pointed wing tips", "Long tail"], "Coastal reefs and sandy flats", "Warm Atlantic waters")
        ]
        return rows.enumerated().map { index, row in
            Species(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(index + 1))), commonName: row.0, scientificName: row.1, summary: row.2, visualCharacteristics: row.3, habitat: row.4, geographicRange: row.5, imageAssetName: nil)
        }
    }()
}
