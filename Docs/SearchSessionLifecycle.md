# Temporary search lifecycle

The existing AppRouter owns one results model per navigable search session. Its
path observer handles explicit back actions and NavigationStack path edits.
Results and unsaved species-detail routes retain their session; saved-identification
routes do not. A detail push or return does not cancel the route-owned task or
remove its cached result. The SwiftUI view task only waits for that work.

When the last route for a flow is removed, the router synchronously cancels its
model and releases ownership, then serially removes the session from the actor
store. Starting a search and loading a results view wait for pending navigation
retention updates. Temporary disappearance is deliberately not a cleanup trigger.

Each load has a unique ownership token. Cancellation invalidates that token and
cancels the service task. Every async boundary is checked before publishing state
or committing results; old completion/cleanup cannot modify a newer load. The
session store checks task cancellation before a result write and cannot recreate
an already removed session. The production service propagates catalogue
cancellation instead of turning it into a catalogue failure.

The in-memory store has a hard default limit of 16 sessions, including active
flows, results and pending sessions. At capacity it evicts the least recently
used inactive session and its unreferenced photo. Navigation-owned sessions are
never evicted. If every slot is active, submission reports that an existing
search must be finished first. No timer is needed for the count bound; otherwise
unused cache entries remain until pressure or process termination. Completed
navigation flows are removed immediately through the router's async cleanup.

Saved sightings contain their own identification/species snapshots in the JSON
repository. A source session ID is provenance, not a dependency on the temporary
store. Reopening the persistent file after releasing the originating session is
covered by a controlled lifecycle test.

Validation: ten controlled async lifecycle tests cover cancellation, immediate
restart, obsolete successes/failures, cancelled writes, detail/back navigation,
temporary view-task cancellation, 30 repeated completed flows, bounded cache,
photo cleanup, and saved-sighting independence. Full Linux SwiftPM execution:
105 tests, zero failures, one opt-in frozen evaluation skipped. SwiftUI source
syntax and git diff whitespace checks pass. Simulator gestures, actual view
lifecycle timing, and device memory behavior are not verified locally; Xcode is
unavailable in this environment.
