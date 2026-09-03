import Foundation

/// Controlled terms shared by bundled catalogue validation and description search.
enum CatalogueVocabulary {
    static let colors: Set<String> = [
        "black", "blue", "brown", "gray", "green", "olive", "orange", "red", "silver", "white", "yellow"
    ]
    static let markings: Set<String> = [
        "barbels", "beak", "eye stripe", "fin edge", "patches", "saddles", "shell", "spines", "spots", "stripes", "tail", "teeth"
    ]
    static let bodyShapes: Set<String> = [
        "compressed", "disk", "elongated", "flat", "oval", "pointed", "robust", "round", "serpentine", "torpedo"
    ]
    static let habitats: Set<String> = [
        "anemone", "deep", "lagoon", "mangrove", "open water", "reef", "rubble", "sand", "seagrass", "shallow", "surface", "wall", "wreck"
    ]
    static let categories: Set<String> = [
        "crustacean", "eel", "fish", "mollusk", "octopus", "ray", "seahorse", "shark", "squid", "turtle"
    ]
    static let behaviors: Set<String> = [
        "anemone association", "bottom-swimming", "burrowing", "cleaning", "feeding", "grazing", "hiding", "hovering", "open-water cruising", "resting", "schooling", "solitary", "swimming"
    ]
    static let regions: Set<String> = [
        "aruba", "atlantic", "bahamas", "belize", "bermuda", "bonaire", "british virgin islands", "caribbean", "cayman islands", "cozumel", "curaçao", "curacao", "dominican republic", "fiji", "florida", "gulf of mexico", "hawaii", "indian", "indo-pacific", "jamaica", "pacific", "puerto rico", "turks and caicos", "us virgin islands", "western atlantic"
    ]
}
