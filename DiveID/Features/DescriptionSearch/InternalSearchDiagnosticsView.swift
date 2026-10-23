#if DEBUG || DIVEID_INTERNAL
import SwiftUI

/// Debug and Internal only (see SearchPerformanceInstrumentation.swift): the selected
/// pack's index source, time to ready and last query time, plus actions that damage the
/// stored index so recovery can be tested on a device after a relaunch.
struct InternalSearchDiagnosticsView: View {
    let packID: OfflineIdentificationPackID
    let diagnostics: InternalSearchDiagnostics
    var store: SearchIndexStore = .shared
    @State private var actionResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("Internal search diagnostics").bold()
            Text(diagnostics.summary(for: packID))
                .accessibilityIdentifier("internalSearchDiagnostics")
            if let breakdown = diagnostics.breakdown(for: packID) {
                Text(breakdown).foregroundStyle(Color.appTextSecondary)
            }
            HStack {
                Button("Delete stored index") {
                    Task {
                        let count = await store.deleteStoredIndex(for: packID)
                        actionResult = "Deleted \(count) stored index file(s). Force-quit and relaunch to test."
                    }
                }
                .accessibilityIdentifier("internalDeleteStoredIndex")
                Button("Corrupt stored index") {
                    Task {
                        let count = await store.corruptStoredIndex(for: packID)
                        actionResult = "Corrupted \(count) stored index file(s). Force-quit and relaunch to test."
                    }
                }
                .accessibilityIdentifier("internalCorruptStoredIndex")
            }
            .buttonStyle(.bordered)
            if let actionResult { Text(actionResult).foregroundStyle(Color.appWarning) }
        }
        .font(.caption2.monospaced())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.Spacing.s)
        .appCard()
    }
}
#endif
