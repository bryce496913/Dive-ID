import SwiftUI

/// "Add details": optional, neutral questions that refine a description search. The diver's
/// description is shown as written and never edited; answers are kept apart from it.
struct RefineSearchSheet: View {
    let originalDescription: String
    let questions: [SearchRefinement.Dimension]
    @State var draft: SearchRefinement
    let onSearch: (SearchRefinement) -> Void
    @State private var showsAll = false
    @State private var lengthText: [SearchRefinement.Dimension: String] = [:]
    @State private var lengthUnit: SearchRefinement.LengthUnit = MeasurementPreference().depthUnit == .feet ? .feet : .centimetres
    @Environment(\.dismiss) private var dismiss
    /// Questions shown before "More questions".
    private let firstQuestions = 3

    init(originalDescription: String, questions: [SearchRefinement.Dimension], draft: SearchRefinement, onSearch: @escaping (SearchRefinement) -> Void) {
        self.originalDescription = originalDescription
        self.questions = questions
        _draft = State(initialValue: draft)
        self.onSearch = onSearch
        if case .measured(let value, let unit)? = draft.answers[.size] {
            _lengthText = State(initialValue: [.size: DiveForm.format(value)])
            _lengthUnit = State(initialValue: unit)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(originalDescription)
                        .accessibilityIdentifier("refineOriginalDescription")
                } header: {
                    Text("Your description")
                } footer: {
                    Text("It stays exactly as you wrote it. Answer any questions below, or skip them; answers are added alongside it.")
                }
                .listRowBackground(Color.appSurface)
                ForEach(visibleQuestions, id: \.self) { dimension in
                    question(dimension)
                }
                if questions.count > firstQuestions && !showsAll {
                    Button("More questions") { withAnimation { showsAll = true } }
                        .accessibilityIdentifier("refineMoreQuestions")
                        .listRowBackground(Color.appSurface)
                }
                if !draft.isEmpty {
                    Section {
                        Button("Clear all answers", role: .destructive) { draft = SearchRefinement(); lengthText = [:] }
                            .accessibilityIdentifier("refineClearAll")
                    }
                    .listRowBackground(Color.appSurface)
                }
            }
            .scrollContentBackground(.hidden)
            .appScreenBackground()
            .navigationTitle("Add Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("refineCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Search Again") { onSearch(draft); dismiss() }
                        .disabled(!isValid)
                        .accessibilityIdentifier("refineSearch")
                }
            }
        }
    }

    private var visibleQuestions: [SearchRefinement.Dimension] { showsAll ? questions : Array(questions.prefix(firstQuestions)) }

    /// A typed length must be a number from 0.5 cm to 20 m in its units; blank is fine.
    private var isValid: Bool { lengthError == nil }
    private var lengthError: String? {
        guard let text = lengthText[.size], !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let value = DiveForm.number(text) else { return "Size must be a number." }
        let centimetres = lengthUnit.centimetres(value)
        return (0.5...2000).contains(centimetres) ? nil : "Size must be between 0.5 cm and 20 m."
    }

    private func question(_ dimension: SearchRefinement.Dimension) -> some View {
        Section {
            if dimension == .size {
                sizeQuestion
            } else {
                ForEach(RefinementQuestions.options[dimension] ?? [], id: \.key) { option in
                    choice(option.label, selected: isSelected(option.key, in: dimension), identifier: "refine_\(dimension.rawValue)_\(option.key)") {
                        toggle(option.key, in: dimension)
                    }
                }
                if dimension == .markings {
                    choice("None of these", selected: draft.answers[dimension] == .noneObserved, identifier: "refine_markings_none") {
                        draft.answers[dimension] = draft.answers[dimension] == .noneObserved ? nil : .noneObserved
                    }
                }
            }
            choice("Not sure", selected: draft.answers[dimension] == .notSure, identifier: "refine_\(dimension.rawValue)_notSure") {
                draft.answers[dimension] = draft.answers[dimension] == .notSure ? nil : .notSure
                if dimension == .size { lengthText[.size] = nil }
            }
            if draft.answers[dimension] != nil {
                Button("Clear this answer") {
                    draft.answers[dimension] = nil
                    if dimension == .size { lengthText[.size] = nil }
                }
                .font(.footnote)
                .accessibilityIdentifier("refine_\(dimension.rawValue)_clear")
            }
        } header: {
            Text(RefinementQuestions.question(dimension))
        } footer: {
            Text(RefinementQuestions.allowsSeveral(dimension) ? "Choose any that you saw. Skip it if you didn't notice." : "Skip it if you didn't notice.")
        }
        .listRowBackground(Color.appSurface)
    }

    @ViewBuilder private var sizeQuestion: some View {
        ForEach(SearchRefinement.SizeBand.allCases, id: \.self) { band in
            choice(RefinementQuestions.sizeBandLabel(band), selected: draft.answers[.size] == .sizeBand(band), identifier: "refine_size_\(band.rawValue)") {
                draft.answers[.size] = draft.answers[.size] == .sizeBand(band) ? nil : .sizeBand(band)
                lengthText[.size] = nil
            }
        }
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack {
                TextField("Or a length", text: Binding(get: { lengthText[.size] ?? "" }, set: { text in
                    lengthText[.size] = text
                    updateMeasuredSize()
                }))
                .keyboardType(.decimalPad)
                .accessibilityLabel("Length")
                .accessibilityIdentifier("refineSizeLength")
                Picker("Units", selection: Binding(get: { lengthUnit }, set: { lengthUnit = $0; updateMeasuredSize() })) {
                    ForEach(SearchRefinement.LengthUnit.allCases, id: \.self) { Text($0.symbol).tag($0) }
                }
                .labelsHidden()
                .accessibilityLabel("Length units")
                .accessibilityIdentifier("refineSizeUnit")
            }
            if let lengthError {
                Text(lengthError).font(.caption).foregroundStyle(Color.appError).accessibilityIdentifier("refineSizeError")
            }
        }
    }

    private func updateMeasuredSize() {
        guard let text = lengthText[.size], !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            if case .measured? = draft.answers[.size] { draft.answers[.size] = nil }
            return
        }
        if lengthError == nil, let value = DiveForm.number(text) {
            draft.answers[.size] = .measured(value: value, unit: lengthUnit)
        }
    }

    private func isSelected(_ key: String, in dimension: SearchRefinement.Dimension) -> Bool {
        if case .values(let keys)? = draft.answers[dimension] { return keys.contains(key) }
        return false
    }

    private func toggle(_ key: String, in dimension: SearchRefinement.Dimension) {
        var keys: Set<String> = []
        if case .values(let current)? = draft.answers[dimension] { keys = Set(current) }
        if keys.contains(key) { keys.remove(key) }
        else if RefinementQuestions.allowsSeveral(dimension) { keys.insert(key) }
        else { keys = [key] }
        draft.answers[dimension] = keys.isEmpty ? nil : .values(keys.sorted())
    }

    private func choice(_ label: String, selected: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).foregroundStyle(Color.appTextPrimary)
                Spacer(minLength: AppTheme.Spacing.s)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(Color.appAccent)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier(identifier)
    }
}

/// What a refined search used, at the top of its results.
struct RefinementSummary: View {
    let refinement: SearchRefinement
    let text: RefinedSearchText?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("Details you added").font(.subheadline.weight(.semibold))
            ForEach(refinement.summaryLines, id: \.self) { Text($0).font(.footnote) }
            if let text, !text.alreadyInDescription.isEmpty {
                Text("Already in your description, so not counted again: \(text.alreadyInDescription.map(RefinementQuestions.title).joined(separator: ", ")).")
                    .font(.footnote).foregroundStyle(Color.appTextSecondary)
            }
            if let text, !text.disagreements.isEmpty {
                Label("Your description and your answer differ for \(text.disagreements.map { RefinementQuestions.title($0).lowercased() }.joined(separator: ", ")). Both were searched; check the matches carefully.",
                      systemImage: "exclamationmark.triangle")
                    .labelStyle(CompactLabelStyle())
                    .font(.footnote).foregroundStyle(Color.appWarning)
                    .accessibilityIdentifier("refinementDisagreement")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("refinementSummary")
    }
}
