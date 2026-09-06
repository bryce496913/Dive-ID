import Foundation

struct SpeciesSearchMeasurements: Codable, Hashable, Sendable {
    let typicalMinimumCentimeters: Double?
    let typicalMaximumCentimeters: Double?
    let maximumRecordedCentimeters: Double?
    let legacyMinimumCentimeters: Double?
    let legacyMaximumCentimeters: Double?
    let type: SpeciesMeasurementType?
}

struct SpeciesSearchDepthRange: Codable, Hashable, Sendable {
    let minimumMeters: Double?
    let maximumMeters: Double?
}

struct SpeciesSearchDocument: Identifiable, Codable, Hashable, Sendable {
    static let schemaVersion = 1

    var id: UUID { speciesID }
    let speciesID: UUID
    let packID: OfflineIdentificationPackID
    let identityText: String
    let appearanceText: String
    let habitatText: String
    let behaviorText: String
    let geographicText: String
    let lifeStageText: String
    let generalText: String
    let combinedText: String
    let measurements: SpeciesSearchMeasurements
    let depthRange: SpeciesSearchDepthRange
    let fingerprint: String
}

protocol SpeciesSearchDocumentBuilding: Sendable {
    func document(from profile: LocalSpeciesProfile, pack: OfflineIdentificationPackMetadata) -> SpeciesSearchDocument
}

struct SpeciesSearchDocumentBuilder: SpeciesSearchDocumentBuilding {
    func document(from profile: LocalSpeciesProfile, pack: OfflineIdentificationPackMetadata) -> SpeciesSearchDocument {
        let identity = text([profile.commonName, profile.scientificName] + profile.aliases)
        let appearance = text(profile.categories + profile.colors + profile.markings + profile.bodyShapes
            + profile.distinguishingFeatures + optional(profile.tailShape)
            + profile.mouthAndHeadShape + profile.finAndSpineClues + profile.keywords)
        let habitat = text(profile.habitats + [profile.typicalHabitat])
        let behavior = text(profile.behaviors)
        let geography = text(profile.regions + profile.subregions + [profile.geographicRange])
        let lifeStage = text(profile.appearanceVariants.flatMap {
            [$0.lifeStage.rawValue] + $0.colors + $0.markings + $0.bodyShapes
                + [$0.description] + $0.distinguishingFeatures
        })
        let general = text([profile.summary])
        let sections = [identity, appearance, habitat, behavior, geography, lifeStage, general].filter { !$0.isEmpty }
        let combined = sections.joined(separator: " | ")
        let fingerprintInput = "\(SpeciesSearchDocument.schemaVersion)\n\(combined)"

        return SpeciesSearchDocument(
            speciesID: profile.id,
            packID: pack.id,
            identityText: identity,
            appearanceText: appearance,
            habitatText: habitat,
            behaviorText: behavior,
            geographicText: geography,
            lifeStageText: lifeStage,
            generalText: general,
            combinedText: combined,
            measurements: SpeciesSearchMeasurements(
                typicalMinimumCentimeters: profile.measurements?.typicalObservedMinimumCentimeters,
                typicalMaximumCentimeters: profile.measurements?.typicalObservedMaximumCentimeters,
                maximumRecordedCentimeters: profile.measurements?.maximumRecordedCentimeters,
                legacyMinimumCentimeters: profile.minimumSizeCentimeters,
                legacyMaximumCentimeters: profile.maximumSizeCentimeters,
                type: profile.measurements?.type
            ),
            depthRange: SpeciesSearchDepthRange(minimumMeters: profile.minimumDepthMeters, maximumMeters: profile.maximumDepthMeters),
            fingerprint: StableSHA256.hexDigest(fingerprintInput)
        )
    }

    private func optional(_ value: String?) -> [String] { value.map { [$0] } ?? [] }

    /// Conservative index normalization: case and whitespace are normalized while
    /// punctuation and taxonomy are retained. Duplicate evidence is removed stably.
    private func text(_ values: [String]) -> String {
        var seen = Set<String>()
        return values.compactMap { value in
            let normalized = value
                .split(whereSeparator: \Character.isWhitespace)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }.joined(separator: " | ")
    }
}

private enum StableSHA256 {
    private static let constants: [UInt32] = [
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
    ]

    static func hexDigest(_ string: String) -> String {
        var message = Array(string.utf8)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        message += withUnsafeBytes(of: bitLength.bigEndian, Array.init)
        var hash: [UInt32] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
        for offset in stride(from: 0, to: message.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 { words[i] = (0..<4).reduce(0) { ($0 << 8) | UInt32(message[offset + i * 4 + $1]) } }
            for i in 16..<64 {
                let s0 = rotate(words[i-15], 7) ^ rotate(words[i-15], 18) ^ (words[i-15] >> 3)
                let s1 = rotate(words[i-2], 17) ^ rotate(words[i-2], 19) ^ (words[i-2] >> 10)
                words[i] = words[i-16] &+ s0 &+ words[i-7] &+ s1
            }
            var a=hash[0], b=hash[1], c=hash[2], d=hash[3], e=hash[4], f=hash[5], g=hash[6], h=hash[7]
            for i in 0..<64 {
                let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let choice = (e & f) ^ ((~e) & g)
                let t1 = h &+ s1 &+ choice &+ constants[i] &+ words[i]
                let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ majority
                h=g; g=f; f=e; e=d &+ t1; d=c; c=b; b=a; a=t1 &+ t2
            }
            let values = [a,b,c,d,e,f,g,h]
            for i in hash.indices { hash[i] = hash[i] &+ values[i] }
        }
        return hash.map { String(format: "%08x", $0) }.joined()
    }

    private static func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}
