import SwiftUI

/// The Dive Log (formerly Saved Identifications): dives newest first, each with its
/// sightings, then the sightings on no dive. Opening a sighting shows the existing
/// saved-identification detail.
struct DiveLogView: View {
    @Bindable var viewModel: DiveLogViewModel
    let router: AppRouter
    @State private var showsNewDive = false
    @State private var exporting: DiveLogExport?
    @State private var confirmingRemoval: SavedIdentification?
    @State private var assigning: SavedIdentification?
    @ScaledMetric(relativeTo: .body) private var thumbnail: CGFloat = 58

    var body: some View {
        VStack(spacing: AppTheme.Spacing.m) {
            if let error = viewModel.errorMessage {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.appError)
                    Button(AppCopy.tryAgain) { Task { await viewModel.retry() } }
                        .disabled(viewModel.isUpdating)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .appCard()
                .padding(.horizontal)
            }
            if viewModel.isLoading {
                LoadingStateView()
            } else if viewModel.isEmpty {
                if viewModel.errorMessage == nil {
                    // Same title as before, so saved-list checks keep working.
                    EmptyStateView(title: "No saved identifications", message: "Save a possible match, or add a dive, to start your dive log.", systemImage: "book")
                }
            } else {
                list
            }
        }
        .appScreenBackground()
        .navigationTitle("Dive Log")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { exporting = .wholeLog(viewModel.dives, unassigned: viewModel.unassigned, regionNames: viewModel.regionNames) } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(viewModel.sightingCount == 0)
                .accessibilityIdentifier("exportLog")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showsNewDive = true } label: { Label("New Dive", systemImage: "plus") }
                    .accessibilityIdentifier("addDive")
            }
        }
        .sheet(isPresented: $showsNewDive) {
            DiveFormView(title: "New Dive", form: Self.newForm(), regions: viewModel.regionChoices) { form in
                await viewModel.save(form) != nil
            }
        }
        .sheet(item: $exporting) { export in DiveLogExportSheet(export: export, name: "dive-log") }
        .sheet(item: $assigning) { sighting in
            DivePicker(dives: viewModel.dives.map(\.dive), regionName: viewModel.regionName) { dive in
                Task { await viewModel.assign([sighting.id], to: dive); assigning = nil }
            }
        }
        .confirmationDialog(
            "Remove this saved identification?",
            isPresented: Binding(get: { confirmingRemoval != nil }, set: { if !$0 { confirmingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: confirmingRemoval
        ) { item in
            Button("Remove \(item.species.commonName)", role: .destructive) { Task { await viewModel.remove(item) } }
        } message: { _ in
            Text("Its saved notes and match details are deleted from this device.")
        }
        .task { await viewModel.load() }
    }

    static func newForm() -> DiveForm {
        let preference = MeasurementPreference()
        return DiveForm(depthUnit: preference.depthUnit, temperatureUnit: preference.temperatureUnit)
    }

    private var list: some View {
        List {
            if !viewModel.dives.isEmpty {
                Section("Dives") {
                    ForEach(viewModel.dives, id: \.dive.id) { entry in
                        Button { router.navigate(to: .dive(id: entry.dive.id)) } label: { diveRow(entry) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("dive_\(entry.dive.id)")
                    }
                }
                .listRowBackground(Color.appSurface)
            }
            if !viewModel.unassigned.isEmpty {
                Section("Unassigned sightings") {
                    ForEach(viewModel.unassigned) { item in
                        Button { router.navigate(to: .savedIdentification(item)) } label: { SightingRow(item: item, thumbnail: thumbnail) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("sighting_\(item.id)")
                            .swipeActions {
                                Button("Remove", role: .destructive) { Task { await viewModel.remove(item) } }
                                    .disabled(viewModel.isUpdating)
                                if !viewModel.dives.isEmpty {
                                    Button("Add to Dive") { assigning = item }.tint(.appAccent)
                                }
                            }
                            // Swipe alone is hard to discover, so long-press offers the same actions.
                            .contextMenu {
                                Button { router.navigate(to: .savedIdentification(item)) } label: { Label("View Details", systemImage: "info.circle") }
                                if !viewModel.dives.isEmpty {
                                    Button { assigning = item } label: { Label("Add to Dive…", systemImage: "plus.circle") }
                                }
                                Button(role: .destructive) { confirmingRemoval = item } label: { Label("Remove", systemImage: "trash") }
                                    .disabled(viewModel.isUpdating)
                            }
                    }
                }
                .listRowBackground(Color.appSurface)
            }
        }
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("diveLog")
    }

    private func diveRow(_ entry: DiveWithSightings) -> some View {
        let dive = entry.dive
        let photo = entry.sightings.first { $0.species.hasPhoto }?.species
        let details = [viewModel.regionName(dive.regionID), dive.maximumDepth.map { "max \(DiveForm.format($0.value)) \($0.unit.symbol)" }]
            .compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: AppTheme.Spacing.m) {
            Group {
                if let photo {
                    SpeciesArtwork(species: photo, showsCaption: false, thumbnailSize: thumbnail)
                } else {
                    Image(systemName: "water.waves").font(.title2).foregroundStyle(Color.appAccent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.appSurfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .frame(width: thumbnail, height: thumbnail)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(DiveText.dateLine(dive)).font(.subheadline).foregroundStyle(Color.appTextSecondary)
                Text(dive.siteName ?? "Unnamed site").font(.headline)
                if !details.isEmpty { Text(details).font(.caption).foregroundStyle(Color.appTextSecondary) }
                Text(DiveText.sightingCount(entry.sightings.count)).font(.caption)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// One saved sighting, as the saved list showed it.
struct SightingRow: View {
    let item: SavedIdentification
    let thumbnail: CGFloat

    var body: some View {
        HStack(spacing: AppTheme.Spacing.m) {
            SpeciesArtwork(species: item.species, showsCaption: false, thumbnailSize: thumbnail)
                .frame(width: thumbnail, height: thumbnail)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(item.species.commonName).font(.headline)
                Text(item.species.scientificName).italic().font(.subheadline).foregroundStyle(Color.appTextSecondary)
                Text("\(item.isFromFieldGuide ? "Saved from the field guide" : item.matchStrength.displayName) · \(item.identifiedAt.formatted(date: .abbreviated, time: .omitted))").font(.caption)
                let detail = item.notes ?? (item.explanation.isEmpty ? item.observationDescription : item.explanation)
                if !detail.isEmpty {
                    Text(detail).lineLimit(2).font(.caption).foregroundStyle(Color.appTextSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

enum DiveText {
    static func dateLine(_ dive: Dive, calendar: Calendar = .current) -> String {
        let date = calendar.date(from: DateComponents(year: dive.date.year, month: dive.date.month, day: dive.date.day)) ?? Date()
        let day = date.formatted(date: .abbreviated, time: .omitted)
        return dive.startTime.map { "\(day) · \($0.description)" } ?? day
    }

    static func sightingCount(_ count: Int) -> String { "\(count) \(count == 1 ? "sighting" : "sightings")" }
}

/// One dive: its details, its sightings, edit, export, add sightings and delete.
struct DiveDetailView: View {
    @Bindable var viewModel: DiveLogViewModel
    let diveID: UUID
    let router: AppRouter
    @State private var editing = false
    @State private var exporting: DiveLogExport?
    @State private var confirmingDelete = false
    @State private var addingSightings = false
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var thumbnail: CGFloat = 58

    var body: some View {
        Group {
            if let entry = viewModel.dive(diveID) {
                content(entry)
            } else if viewModel.isLoading {
                LoadingStateView()
            } else {
                EmptyStateView(title: "Dive not found", message: "This dive may have been deleted.", systemImage: "water.waves")
            }
        }
        .appScreenBackground()
        .navigationTitle(viewModel.dive(diveID)?.dive.siteName ?? "Dive")
        .task { await viewModel.load() }
    }

    private func content(_ entry: DiveWithSightings) -> some View {
        let dive = entry.dive
        return List {
            if let error = viewModel.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.appError)
                    Button(AppCopy.tryAgain) { Task { await viewModel.retry() } }
                }
                .listRowBackground(Color.appSurface)
            }
            Section("Dive") {
                LabeledContent("Date", value: DiveText.dateLine(dive))
                if let site = dive.siteName { LabeledContent("Site", value: site) }
                if let region = viewModel.regionName(dive.regionID) { LabeledContent("Region", value: region) }
                if let depth = dive.maximumDepth { LabeledContent("Maximum depth", value: "\(DiveForm.format(depth.value)) \(depth.unit.symbol)") }
                if let minutes = dive.durationMinutes { LabeledContent("Duration", value: "\(minutes) min") }
                if let temperature = dive.waterTemperature { LabeledContent("Water", value: "\(DiveForm.format(temperature.value)) \(temperature.unit.symbol)") }
                if let visibility = dive.visibility { LabeledContent("Visibility", value: "\(DiveForm.format(visibility.value)) \(visibility.unit.symbol)") }
                if let notes = dive.notes { Text(notes).foregroundStyle(Color.appTextSecondary) }
            }
            .listRowBackground(Color.appSurface)
            Section(DiveText.sightingCount(entry.sightings.count)) {
                ForEach(entry.sightings) { item in
                    Button { router.navigate(to: .savedIdentification(item)) } label: { SightingRow(item: item, thumbnail: thumbnail) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("sighting_\(item.id)")
                        .swipeActions {
                            Button("Remove from Dive") { Task { await viewModel.unassign([item.id]) } }.tint(.appWarning)
                        }
                        .contextMenu {
                            Button { Task { await viewModel.unassign([item.id]) } } label: { Label("Remove from Dive", systemImage: "minus.circle") }
                        }
                }
                if !viewModel.unassigned.isEmpty {
                    Button { addingSightings = true } label: { Label("Add Sightings", systemImage: "plus.circle") }
                        .accessibilityIdentifier("addSightings")
                }
            }
            .listRowBackground(Color.appSurface)
            Section {
                Button("Delete Dive", role: .destructive) { confirmingDelete = true }
                    .accessibilityIdentifier("deleteDive")
            }
            .listRowBackground(Color.appSurface)
        }
        .scrollContentBackground(.hidden)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { exporting = .oneDive(entry, regionNames: viewModel.regionNames) } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(entry.sightings.isEmpty)
                    .accessibilityIdentifier("exportDive")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { editing = true }.accessibilityIdentifier("editDive")
            }
        }
        .sheet(isPresented: $editing) {
            DiveFormView(title: "Edit Dive", form: DiveForm(editing: dive, depthUnit: MeasurementPreference().depthUnit,
                                                             temperatureUnit: MeasurementPreference().temperatureUnit),
                         regions: viewModel.regionChoices) { form in
                await viewModel.save(form, editing: dive) != nil
            }
        }
        .sheet(item: $exporting) { export in DiveLogExportSheet(export: export, name: dive.siteName ?? dive.date.description) }
        .sheet(isPresented: $addingSightings) {
            SightingPicker(sightings: viewModel.unassigned) { chosen in
                Task { await viewModel.assign(chosen, to: dive); addingSightings = false }
            }
        }
        // Keeping the sightings is the default (first, not destructive).
        .confirmationDialog("Delete this dive?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Dive, Keep Sightings") { Task { await viewModel.delete(dive, sightings: .keepUnassigned); dismiss() } }
                .accessibilityIdentifier("deleteKeepSightings")
            Button("Delete Dive and Its Sightings", role: .destructive) { Task { await viewModel.delete(dive, sightings: .deleteSightings); dismiss() } }
        } message: {
            Text("Kept sightings move to Unassigned sightings.")
        }
    }
}

/// The add/edit dive form. Units follow the setting; changing them here changes the setting.
struct DiveFormView: View {
    let title: String
    @State var form: DiveForm
    let regions: [OfflineIdentificationPackMetadata]
    let onSave: (DiveForm) async -> Bool
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let errors = form.errors
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $form.date, displayedComponents: .date).accessibilityIdentifier("diveDate")
                    Toggle("Start time", isOn: $form.hasStartTime.animation()).accessibilityIdentifier("diveHasStartTime")
                    if form.hasStartTime {
                        DatePicker("Time", selection: $form.startTime, displayedComponents: .hourAndMinute).accessibilityIdentifier("diveStartTime")
                    }
                    TextField("Site name", text: $form.siteName).accessibilityIdentifier("diveSite")
                    Picker("Region", selection: $form.regionID) {
                        Text("None").tag(OfflineIdentificationPackID?.none)
                        ForEach(regions) { pack in Text(pack.displayName).tag(Optional(pack.id)) }
                    }
                    .accessibilityIdentifier("diveRegion")
                }
                .listRowBackground(Color.appSurface)
                Section {
                    Picker("Units", selection: Binding(get: { form.depthUnit }, set: { unit in
                        form.depthUnit = unit
                        form.temperatureUnit = unit == .feet ? .fahrenheit : .celsius
                        MeasurementPreference().depthUnit = unit
                    })) {
                        Text("Metres, °C").tag(DepthUnit.metres)
                        Text("Feet, °F").tag(DepthUnit.feet)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("diveUnits")
                    measurement("Maximum depth", $form.depthText, form.depthUnit.symbol, "diveDepth", errors[.maximumDepth])
                    measurement("Duration", $form.durationText, "min", "diveDuration", errors[.duration], keyboard: .numberPad)
                    measurement("Water temperature", $form.temperatureText, form.temperatureUnit.symbol, "diveTemperature", errors[.waterTemperature],
                                keyboard: .numbersAndPunctuation)
                    measurement("Visibility", $form.visibilityText, form.depthUnit.symbol, "diveVisibility", errors[.visibility])
                } footer: {
                    Text("Everything except the date is optional.")
                }
                .listRowBackground(Color.appSurface)
                Section("Notes") {
                    TextField("Notes", text: $form.notes, axis: .vertical).lineLimit(3...8).accessibilityIdentifier("diveNotes")
                }
                .listRowBackground(Color.appSurface)
            }
            .scrollContentBackground(.hidden)
            .appScreenBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isSaving = true
                        Task { if await onSave(form) { dismiss() }; isSaving = false }
                    }
                    .disabled(!errors.isEmpty || isSaving)
                    .accessibilityIdentifier("saveDive")
                }
            }
        }
    }

    private func measurement(_ label: String, _ text: Binding<String>, _ unit: String, _ identifier: String, _ error: String?,
                             keyboard: UIKeyboardType = .decimalPad) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            HStack {
                TextField(label, text: text).keyboardType(keyboard).accessibilityIdentifier(identifier)
                Text(unit).foregroundStyle(Color.appTextSecondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(Color.appError).accessibilityIdentifier("\(identifier)Error")
            }
        }
    }
}

/// Pick a dive (newest first).
struct DivePicker: View {
    let dives: [Dive]
    let regionName: (OfflineIdentificationPackID?) -> String?
    let onPick: (Dive) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(dives) { dive in
                Button { onPick(dive) } label: {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        Text(dive.siteName ?? "Unnamed site").font(.headline)
                        Text([DiveText.dateLine(dive), regionName(dive.regionID)].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(Color.appTextSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.appSurface)
                .accessibilityIdentifier("pickDive_\(dive.id)")
            }
            .scrollContentBackground(.hidden)
            .appScreenBackground()
            .navigationTitle("Choose a Dive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// Pick unassigned sightings to add to a dive.
private struct SightingPicker: View {
    let sightings: [SavedIdentification]
    let onAdd: ([UUID]) -> Void
    @State private var chosen = Set<UUID>()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(sightings) { item in
                Button {
                    if chosen.contains(item.id) { chosen.remove(item.id) } else { chosen.insert(item.id) }
                } label: {
                    HStack {
                        SightingRow(item: item, thumbnail: 44)
                        Image(systemName: chosen.contains(item.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(Color.appAccent)
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.appSurface)
                .accessibilityAddTraits(chosen.contains(item.id) ? .isSelected : [])
            }
            .scrollContentBackground(.hidden)
            .appScreenBackground()
            .navigationTitle("Add Sightings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add") { onAdd(Array(chosen)) }.disabled(chosen.isEmpty) }
            }
        }
    }
}

/// The export preview: format, row count, then the share sheet.
struct DiveLogExportSheet: View {
    let export: DiveLogExport
    let name: String
    @State private var format: DiveLogExport.Format = .csv
    @State private var fileURL: URL?
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Picker("Format", selection: $format) {
                    Text("CSV (spreadsheet)").tag(DiveLogExport.Format.csv)
                    Text("JSON (everything)").tag(DiveLogExport.Format.json)
                }
                .pickerStyle(.inline)
                .accessibilityIdentifier("exportFormat")
                Section {
                    Text("\(export.rowCount) \(export.rowCount == 1 ? "sighting" : "sightings") in \(export.dives.count) \(export.dives.count == 1 ? "dive" : "dives")"
                         + (export.unassigned.isEmpty ? "" : ", including \(export.unassigned.count) on no dive"))
                        .accessibilityIdentifier("exportRowCount")
                    Text(format == .csv ? "One row per sighting, with its dive's details." : "Every field of every dive and sighting.")
                        .font(.footnote).foregroundStyle(Color.appTextSecondary)
                    if let errorMessage { Text(errorMessage).foregroundStyle(Color.appError) }
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if let fileURL { ShareLink(item: fileURL) { Text("Share") }.accessibilityIdentifier("exportShare") }
                }
            }
            .task(id: format) {
                do { fileURL = try export.write(format, name: name); errorMessage = nil }
                catch { fileURL = nil; errorMessage = "The export file could not be written. Check available storage and try again." }
            }
        }
    }
}

extension DiveLogExport: Identifiable {
    var id: String { "\(dives.map(\.dive.id)) \(unassigned.count) \(exportedAt.timeIntervalSince1970)" }
}
