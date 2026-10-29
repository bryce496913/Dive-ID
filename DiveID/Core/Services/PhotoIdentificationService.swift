import Foundation

/// Photo-matching constants (Docs/HybridRankingContract.md#photo-evidence).
enum PhotoMatchingWeights {
    /// Normalized similarity the best photo candidate needs, and every kept candidate needs.
    /// Provisional: to be set from development data before any evaluation.
    static let abstainSimilarity = 0.5
    /// Weight of normalized photo similarity in the ordering score, the same as normalized
    /// retrieval relevance. Ordering only: it never changes confidence.
    static let ordering = 8.0
    static let explanation = "Looks similar to the reference photo."
}

/// Identifies from the diver's photo, optionally with their extra text, on the device.
struct PhotoIdentificationService: Sendable {
    let recognizers: any PhotoRecognizerProviding
    let searchEngine: any DescriptionSearching

    init(recognizers: any PhotoRecognizerProviding, searchEngine: any DescriptionSearching = HybridDescriptionSearchEngine()) {
        self.recognizers = recognizers
        self.searchEngine = searchEngine
    }

    /// The service for this build, or nil when photo identification is off (Release).
    static func forApp(features: FeatureAvailability, searchEngine: any DescriptionSearching,
                       recognizers: any PhotoRecognizerProviding) -> PhotoIdentificationService? {
        features.photoIdentificationEnabled ? PhotoIdentificationService(recognizers: recognizers, searchEngine: searchEngine) : nil
    }

    /// `pack` is loaded by the caller with the build's catalogue access, as for a description.
    func identify(photo: ProcessedPhoto, additionalDescription: String?, pack: OfflineIdentificationPack) async throws -> IdentificationOutcome {
        try Task.checkCancellation()
        guard let recognizer = try await recognizers.recognizer(for: pack) else { throw LocalIdentificationError.photoRecognizerUnavailable }
        let version = pack.photoCatalogueContentVersion
        let recognition = try await Self.offMainActor { try await recognizer.recognize(photo, catalogueContentVersion: version) }
        try Task.checkCancellation()

        var text: DescriptionSearchResult?
        let trimmed = additionalDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.count >= 3 {
            let result = try await searchEngine.search(description: trimmed, pack: pack)
            try Task.checkCancellation()
            if result.queryAnalysis.packRegionCompatibility == .conflicting,
               let outside = result.queryAnalysis.observedRegions.sorted().first {
                throw LocalIdentificationError.regionMismatch(selected: pack.metadata.id, mentionedRegion: outside.capitalized)
            }
            text = result
        }
        let fused = PhotoEvidenceFusion.fuse(recognition: recognition, text: text, pack: pack, observationDescription: text == nil ? "" : trimmed)
        let packIDs = Set(pack.profiles.map(\.id))
        let summary = PhotoMatchSummary(
            recognizerID: recognizer.recognizerID, recognizerVersion: recognizer.version,
            coveredSpeciesCount: recognizer.coveredSpeciesIDs.intersection(packIDs).count,
            catalogueSpeciesCount: pack.profiles.count, abstained: fused.photoAbstained,
            isPlaceholder: recognizer.isPlaceholder, usedDescription: text != nil)
        return IdentificationOutcome(matches: fused.matches, photoSummary: summary)
    }

    /// Runs recognizer work in a detached task, never on the main actor, and passes cancellation on.
    static func offMainActor<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: work)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

/// The fusion rule in Docs/HybridRankingContract.md#photo-evidence. Pure, so it is tested directly.
enum PhotoEvidenceFusion {
    struct Result {
        let matches: [IdentificationMatch]
        let photoAbstained: Bool
    }

    static func fuse(recognition: PhotoRecognition, text: DescriptionSearchResult?, pack: OfflineIdentificationPack,
                     observationDescription: String = "") -> Result {
        let profiles = Dictionary(pack.profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // In-pack candidates only (publication filtering), best similarity per species.
        var photo: [UUID: (similarity: Double, evidence: PhotoMatchEvidence)] = [:]
        for candidate in recognition.candidates where profiles[candidate.speciesID] != nil {
            let similarity = candidate.similarity.normalized
            if similarity > (photo[candidate.speciesID]?.similarity ?? -1) { photo[candidate.speciesID] = (similarity, candidate.evidence) }
        }
        let best = photo.values.map(\.similarity).max() ?? 0
        let abstained = recognition.abstained || best < PhotoMatchingWeights.abstainSimilarity
        if abstained { photo = [:] } else { photo = photo.filter { $0.value.similarity >= PhotoMatchingWeights.abstainSimilarity } }

        struct Scored { let tier: Int; let ordering: Double; let match: IdentificationMatch }
        var scored: [Scored] = []
        var seen = Set<UUID>()
        for candidate in text?.candidates ?? [] where seen.insert(candidate.profile.id).inserted {
            let photoTerm = photo[candidate.profile.id]
            var match = LocalMarineLifeIdentificationService.match(for: candidate, pack: pack, observationDescription: observationDescription)
            if let photoTerm {
                match.explanation = PhotoMatchingWeights.explanation + " " + match.explanation
                match.photoEvidence = photoTerm.evidence
            }
            scored.append(Scored(tier: 1, ordering: candidate.orderingScore + PhotoMatchingWeights.ordering * (photoTerm?.similarity ?? 0), match: match))
        }
        for (id, term) in photo where !seen.contains(id) {
            guard let profile = profiles[id] else { continue }
            let confidence = min(term.similarity, LocalRankingWeights.limitedConfidenceCap)
            var species = profile.species
            species.packContext = PackContext(packID: pack.metadata.id, displayName: pack.metadata.displayName, packVersion: pack.metadata.packVersion)
            var match = IdentificationMatch(id: id, species: species, score: confidence, scoreKind: .relativeMatch,
                                            strength: MatchStrength.band(for: confidence), explanation: PhotoMatchingWeights.explanation,
                                            distinguishingFeatures: profile.distinguishingFeatures, cautions: profile.cautions,
                                            taxonomicResolution: .species, observationDescription: observationDescription)
            match.packContext = species.packContext
            match.informationLevel = .limited
            match.photoEvidence = term.evidence
            scored.append(Scored(tier: 2, ordering: PhotoMatchingWeights.ordering * term.similarity, match: match))
        }
        let ordered = scored.sorted { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            if a.ordering != b.ordering { return a.ordering > b.ordering }
            let names = a.match.species.commonName.localizedStandardCompare(b.match.species.commonName)
            if names != .orderedSame { return names == .orderedAscending }
            return a.match.species.id.uuidString < b.match.species.id.uuidString
        }
        let matches = ordered.prefix(10).enumerated().map { index, entry in
            var match = entry.match
            match.rank = index + 1
            return match
        }
        return Result(matches: matches, photoAbstained: abstained)
    }
}
