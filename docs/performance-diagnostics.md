# iPhone performance diagnostics

Build 0.1.1 (2026091801) isolates meal-name and AI food-review name editing from expensive parent forms. Recent ingredient suggestions are ranked when the product snapshot changes, rather than on each name keystroke. Install a Release build for performance assessment.

In Goals, Performance diagnostics shows the build and session UUID. “Mark this session as slow” creates a timestamped report. A new app process starts a new session. Foreground heartbeat gaps over 150 ms, sampled input-to-next-main-queue timings, screen labels, meal suggestion ranking and AI operation durations are recorded. These are timing clues, not call stacks; a heartbeat gap alone does not establish a root cause. Input timing measures queue delay after SwiftUI delivers the edit, not the full physical-key-to-display latency.

Events exclude food text, typed characters, credentials, AI payloads and user identifiers. The file `Library/ThistleData/performance-events.json` retains at most 2,000 events, dropping events older than 29 days. A background actor writes the bounded queue. Upload attempts occur every 30 seconds while foregrounded and on foreground/background transitions. Each attempt sends at most four batches of 100; failures retain the queue for a future attempt. Background execution is best-effort.

Private provisioning: write `Library/ThistleData/diagnostics-config.json` in the app container with `endpoint` and an upload-only `token`. Never commit this file. The personal deployment uses the existing Y-wing HTTP server through encrypted Tailscale; the iPhone must have Tailscale enabled and Local Network access allowed. The app includes a narrowly scoped ATS exception for that host. HTTPS endpoints are also accepted.

The receiver in `tools/diagnostics/thistle_diagnostics.py` validates exact fields and fixed event/screen labels, authenticates against a separate `thistle-upload-token`, deduplicates event IDs, and stores at most 50,000 events for 30 days. The home server route is `/api/thistle/performance`: POST accepts only the upload credential, GET requires the existing home-server admin session cookie. Never give the phone the home-server admin credential.

Agents on Y-wing can query:

```sh
python3 -m instinct_server.thistle_diagnostics --state-dir "$HOME/Library/Application Support/InstinctHome/state"
# Add --session UUID for individual timing events.
```

The home bot receives recent diagnostic summaries when Thistle is selected/mentioned or a message describes iPhone slowness. It has curated handoff notes, not a live mirror of every Codex session. Missing events mean unknown; older builds cannot retrospectively report performance.

Verification: Release device and simulator builds; receiver authentication, schema/privacy rejection, invalid timings, duplicate delivery, and session filtering tests. Physical typing smoothness still requires an on-device check.

To disable uploads, remove the private config from the app container. To remove collection, remove the lifecycle/view instrumentation and diagnostics service. The receiver runs inside the existing home service (no additional launch daemon); remove its two routes/imports and module, revoke/delete the upload token, and optionally delete `thistle-performance.sqlite3`. Restart the home service after code changes.
