import SwiftUI

/// "Was this right?" below the results: three answers of equal weight, none preselected.
struct FeedbackPrompt: View {
    @Bindable var model: FeedbackPromptViewModel
    /// The results as shown, to pick "this one" from.
    let matches: [IdentificationMatch]

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            Text("Was this right?").font(.headline).accessibilityAddTraits(.isHeader)
            Text("Your answer is saved only on this device. Nothing is sent.")
                .font(.footnote).foregroundStyle(Color.appTextSecondary)
            if let saved = model.savedAnswer {
                Label(savedText(saved), systemImage: "checkmark.circle.fill")
                    .font(.subheadline).foregroundStyle(Color.appSuccess)
                    .accessibilityIdentifier("feedbackSaved")
                Text("You can change your answer below.").font(.footnote).foregroundStyle(Color.appTextSecondary)
            }
            // Same style, same width, fixed order: none is suggested.
            FeedbackAnswerButton(title: "Yes — this one", identifier: "feedbackYes") { model.chooseYes() }
            FeedbackAnswerButton(title: "None of these", identifier: "feedbackNone") { model.choose(.noneOfThese) }
            FeedbackAnswerButton(title: "Not sure", identifier: "feedbackNotSure") { model.choose(.notSure) }
            FeedbackError(model: model)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .appCard()
        // A container keeps its children's own identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("feedbackPrompt")
        .feedbackFlow(model: model, matches: matches)
        .task { await model.load() }
    }

    private func savedText(_ answer: FeedbackAnswer) -> String {
        switch answer {
        case .claimed(let id): "Saved: “\(matches.first { $0.species.id == id }?.species.commonName ?? "this species")” was what you saw."
        case .noneOfThese: "Saved: none of these."
        case .notSure: "Saved: not sure."
        }
    }
}

/// "This is what I saw" on a species page reached from a search.
struct FeedbackThisIsWhatISawButton: View {
    @Bindable var model: FeedbackPromptViewModel
    let species: Species

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            if model.savedAnswer == .claimed(speciesID: species.id) {
                Label("Saved: this is what you saw.", systemImage: "checkmark.circle.fill")
                    .font(.subheadline).foregroundStyle(Color.appSuccess)
                    .accessibilityIdentifier("feedbackSaved")
            } else {
                FeedbackAnswerButton(title: "This is what I saw", identifier: "feedbackThisIsWhatISaw") {
                    model.choose(.claimed(speciesID: species.id))
                }
            }
            FeedbackError(model: model)
        }
        .feedbackFlow(model: model, matches: [])
        .task { await model.load() }
    }
}

private struct FeedbackAnswerButton: View {
    let title: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(.appAccent)
        .accessibilityIdentifier(identifier)
    }
}

private struct FeedbackError: View {
    let model: FeedbackPromptViewModel
    var body: some View {
        if let error = model.errorMessage, model.activeStep == nil {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.appError)
                Button(AppCopy.tryAgain) { Task { await model.retry() } }
                    .disabled(model.isSaving)
                    .accessibilityIdentifier("feedbackRetry")
            }
        }
    }
}

private extension View {
    func feedbackFlow(model: FeedbackPromptViewModel, matches: [IdentificationMatch]) -> some View {
        sheet(isPresented: Binding(get: { model.activeStep != nil }, set: { if !$0 { model.cancel() } })) {
            NavigationStack {
                FeedbackSheetContent(model: model, matches: matches)
            }
            .presentationDetents([.large])
        }
    }
}

private struct FeedbackSheetContent: View {
    @Bindable var model: FeedbackPromptViewModel
    let matches: [IdentificationMatch]

    var body: some View {
        Group {
            switch model.activeStep {
            case .pickMatch: picker
            case .consent: FeedbackConsentForm(model: model)
            case .details, nil: details
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { model.cancel() }.accessibilityIdentifier("feedbackCancel")
            }
        }
        .appScreenBackground()
    }

    /// The results in the order shown, none highlighted.
    private var picker: some View {
        List {
            Section {
                ForEach(matches) { match in
                    Button { model.choose(.claimed(speciesID: match.species.id)) } label: {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                            Text(match.species.commonName).font(.headline)
                            Text(match.species.scientificName).italic().font(.subheadline).foregroundStyle(Color.appTextSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.appSurface)
                    .accessibilityIdentifier("feedbackPick_\(match.species.id)")
                }
            } header: {
                Text("Which one did you see?").textCase(nil).font(.subheadline)
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("This one")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var details: some View {
        Form {
            Section {
                Text("All optional. Add only what you're comfortable sharing; no exact locations.")
                    .font(.footnote).foregroundStyle(Color.appTextSecondary)
                TextField("Broad region, e.g. Red Sea or Florida Keys", text: $model.details.broadRegion)
                    .accessibilityIdentifier("feedbackRegion")
                HStack {
                    TextField("Approximate depth", text: $model.details.depthText)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("feedbackDepth")
                    Picker("Units", selection: $model.details.depthUnit) {
                        Text("m").tag(DepthUnit.metres)
                        Text("ft").tag(DepthUnit.feet)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 120)
                    .accessibilityIdentifier("feedbackDepthUnit")
                }
                TextField("Anything you're unsure about", text: $model.details.uncertainty, axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("feedbackUncertainty")
                Toggle("I have a photo I can send", isOn: $model.details.hasPhotoToSend)
                    .accessibilityIdentifier("feedbackHasPhoto")
            }
            .listRowBackground(Color.appSurface)
            Section {
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.appError)
                }
                Button(model.errorMessage == nil ? "Save feedback" : AppCopy.tryAgain) {
                    Task { if model.errorMessage == nil { await model.save() } else { await model.retry() } }
                }
                .disabled(model.isSaving)
                .accessibilityIdentifier("feedbackSave")
            }
            .listRowBackground(Color.appSurface)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Add details")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Shown once, before the first feedback is saved. Both consents are optional and off.
private struct FeedbackConsentForm: View {
    @Bindable var model: FeedbackPromptViewModel

    var body: some View {
        Form {
            Section {
                Text("Your feedback stays on this phone. Nothing is sent unless you choose Share my feedback later, in Data Sources and Credits.")
                Text("If you share it, your descriptions can help test how well Dive ID identifies animals. You can say yes to either, both or neither, and change your mind in Data Sources and Credits. Saying no doesn't change how the app works.")
                    .foregroundStyle(Color.appTextSecondary)
            }
            .listRowBackground(Color.appSurface)
            Section {
                Toggle("Use my descriptions to test Dive ID", isOn: $model.consentDraft.forEvaluation)
                    .accessibilityIdentifier("consentEvaluation")
                Toggle("Dive ID may quote my wording", isOn: $model.consentDraft.forPublication)
                    .accessibilityIdentifier("consentPublication")
            } footer: {
                Text("Feedback is stored with a random participant code, never your name, location or device details.")
            }
            .listRowBackground(Color.appSurface)
            Section {
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.appError)
                }
                Button("Continue") { Task { await model.confirmConsent() } }
                    .disabled(model.isSaving)
                    .accessibilityIdentifier("consentContinue")
            }
            .listRowBackground(Color.appSurface)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Your feedback")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Credits' "Your search feedback" card: consent, counts, and Share my feedback.
struct FeedbackSharingCard: View {
    @Bindable var model: FeedbackSharingViewModel
    @State private var showsPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            Text("Your search feedback").font(.headline)
            Text("Answers to “Was this right?” are saved only on this phone. Participant code: \(model.participantCode)")
                .font(.subheadline).foregroundStyle(Color.appTextSecondary)
            Toggle("Use my descriptions to test Dive ID", isOn: Binding(
                get: { model.consent.forEvaluation },
                set: { value in Task { await model.updateConsent(FeedbackConsent(forEvaluation: value, forPublication: model.consent.forPublication)) } }))
                .accessibilityIdentifier("settingsConsentEvaluation")
            Toggle("Dive ID may quote my wording", isOn: Binding(
                get: { model.consent.forPublication },
                set: { value in Task { await model.updateConsent(FeedbackConsent(forEvaluation: model.consent.forEvaluation, forPublication: value)) } }))
                .accessibilityIdentifier("settingsConsentPublication")
            Text("\(model.savedCount) saved, \(model.shareableCount) can be shared")
                .font(.subheadline)
                .accessibilityIdentifier("feedbackCounts")
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.appError)
                Button(AppCopy.tryAgain) { Task { await model.load() } }
            }
            Button {
                Task { await model.prepareExport(); showsPreview = model.export != nil }
            } label: {
                Label("Share my feedback", systemImage: "square.and.arrow.up")
            }
            .disabled(model.shareableCount == 0)
            .accessibilityIdentifier("shareFeedback")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .appCard()
        // A container keeps its children's own identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("feedbackSharing")
        .task { await model.load() }
        .sheet(isPresented: $showsPreview) {
            NavigationStack { FeedbackExportPreview(model: model) }
        }
    }
}

/// What will be shared, before the share sheet opens.
private struct FeedbackExportPreview: View {
    let model: FeedbackSharingViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let export = model.export {
                Section {
                    Text("\(export.records.count) \(export.records.count == 1 ? "record" : "records") will be shared as one file. Records without consent to test Dive ID are left out.")
                        .accessibilityIdentifier("exportCount")
                }
                .listRowBackground(Color.appSurface)
                Section("Preview") {
                    ForEach(export.records) { record in
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                            Text("“\(record.originalDescription)”").font(.subheadline)
                            Text("\(record.createdAt.formatted(date: .abbreviated, time: .shortened)) · answer: \(record.answer)"
                                 + (record.consentForPublication ? " · may be quoted" : " · not to be quoted"))
                                .font(.caption).foregroundStyle(Color.appTextSecondary)
                        }
                    }
                }
                .listRowBackground(Color.appSurface)
            }
        }
        .scrollContentBackground(.hidden)
        .appScreenBackground()
        .navigationTitle("Share my feedback")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if let url = model.exportURL {
                    ShareLink(item: url) { Text("Share") }.accessibilityIdentifier("exportShare")
                }
            }
        }
    }
}
