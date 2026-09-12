# iOS Reliability and Release Readiness

## Goal

Address the five review recommendations: stop unnecessary location updates after terminal connection failure, automate verification, clarify shooting readiness, provide in-app support and safe diagnostic summaries, and qualify the exact A7C II identity for public Release.

Status: The software portion is delivered in [Draft PR #17](https://github.com/narumiruna/camera-gps-link/pull/17) on `narumi/feat/ios-reliability-release-readiness`, based on `origin/main` at `b51685fe9b51a89daa7a03d291204ec49de2b18d`. Signed implementation commit `42ac9efac9968ac3e7f7e78a3f4ac31f1bb3a9b7` passes both the local gate and hosted CI. Public document destinations and physical qualification remain blocked; this plan is not complete.

## Context

These findings describe the pre-implementation baseline at `b51685f`.

- `CameraGPSLink/CameraGPSLinkAppModel.swift:614` clears `linkRequested` on some terminal snapshots without stopping the location service. This is a static finding; reproduction and verification of BLE intent transitions come before a fix.
- Terminal intent is not uniform: `CameraBLEManager+CoreBluetooth.swift` clears persisted intent for unsupported profiles and incomplete cleanup, while `CameraBLEManager+Operations.swift` has failure paths that require closer inspection. A foreground failure must not become background retry merely because Background is configured.
- `CameraGPSLink/SonyReleasePolicy.swift` deliberately has an empty public `verifiedEntries` registry and disables public background operation. `docs/compatibility/ilce-7cm2-2.01.md` records passing DEBUG foreground evidence, not Release-equivalent qualification.
- The home screen already separates iPhone fix health from the last confirmed camera update. It lacks a persistent foreground-only explanation, and a fresh camera cache can retain the green Ready presentation while the phone fix is stale.
- `justfile` provides the local verification gate, but `.github/` contains no workflow. Recipes assume `/Applications/Xcode.app`, an iPhone 17 simulator, and the latest installed iOS runtime. The inspected local toolchain is Xcode 26.6; hosted-runner availability is not established.
- Privacy and support documents exist, but `LinkSettingsView.swift` exposes no links. `DiagnosticsView.swift` copies only log text; `DiagnosticsLogStore.swift` does not guarantee removal of coordinates from arbitrary free-form messages.
- `CameraGPSLinkUnitTests/CameraGPSLinkUnitTests.swift` is already 999 lines. Add focused test files or move the relevant fixtures before extending it; every Swift source must remain at most 1000 lines.

## Architecture

- `CameraBLEManager` owns camera attempt origin, persisted link intent, retry eligibility, and camera-control cleanup. `CameraGPSLinkAppModel` reconciles that intent with location-service lifetime; views do not stop services directly.
- Terminal reconciliation must be idempotent when location publications trigger `serviceDidChange` again. Preserve required camera cleanup and existing unexpected-loss alerts; do not call `healthMonitor.endSession()` for every failure as if the user pressed Stop.
- `GeotaggingViewState` owns presentation decisions. Keep the two-minute phone-fix and five-minute camera-update policies unchanged; a BLE acknowledgment does not prove that any individual photo contains GPS EXIF.
- Diagnostic summaries use an explicit field allowlist and contain no coordinates, user-assigned camera names, peripheral identifiers, raw payloads, or arbitrary error/log strings. Existing log copying remains a separate, explicitly warned action. Neither action uploads data.
- CI reuses `just` recipes with one consistent Xcode selection. Unit and UI test hosts run on separate runners or sequentially with the existing simulator reset behavior.

## Non-Goals

- Additional camera models or firmware, public background enablement, protocol changes, location-history storage, analytics, and automatic diagnostic uploads.
- A general BLE or app-model rewrite, unrelated plan maintenance, and a full App Store submission or metadata project.

## Assumptions

- Scope is all five recommendations; hardware-independent changes can be reviewed and merged before physical qualification, but that does not complete this plan.
- GitHub Actions access, an appropriate hosted Xcode/runtime, public document URLs, signing access, and an iPhone with an A7C II on firmware 2.01 must be verified during execution.
- Every physical camera write session requires fresh explicit authorization covering the camera, coordinate source, and bounded test window. Historical authorization does not apply to this work.

## Plan

### 1. Establish the execution prerequisites

- [x] Run `just check` before implementation to establish a baseline. Initial `b51685f` run failed at `ios-typecheck`: active CommandLineTools Swift 6.4 could not load Xcode SwiftUI macros. The explicit `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer just check` baseline passed all builds, 122 unit tests, and 29 UI tests using Xcode 26.6 (`17F113`), Swift 6.3.3, and iOS Simulator 26.5 (`23F77`). Logs: `/tmp/camera-gps-link-readiness/baseline*.log`.
- [x] Map terminal failure, unsupported identity, Bluetooth-unavailable, cleanup, and background-retry paths to intent and location lifetime; the transition contract is recorded in `LocationSessionLifecycleTests.swift`, with manager behavior tested separately in `CameraBLELifecycleTests.swift`. The red run reproduced both retained terminal intent and GPS continuing after cleared intent.
- [x] Verify a GitHub-hosted macOS/Xcode/runtime combination compatible with the project and an available simulator device type. The successful [hosted run](https://github.com/narumiruna/camera-gps-link/actions/runs/34680667403) recorded `macos-26-arm64` image `20260907.0351.1`, macOS 26.6.2 (`25G83`), Xcode 26.6 (`17F113`), Swift 6.3.3, iOS Simulator 26.5 (`23F77`), and iPhone 17. This matches the selected [runner image manifest](https://github.com/actions/runner-images/blob/0af81b6d930d02b52941d584bee9214c4bc228c6/images/macos/macos-26-arm64-Readme.md).
- [ ] Confirm public HTTPS destinations for `docs/PRIVACY.md` and `docs/SUPPORT.md`; record URLs that open without authentication and use those same destinations in the app. Blocked on 2026-09-12: `gh repo view` confirms this repository is private and anonymous requests to both `https://github.com/narumiruna/camera-gps-link/blob/main/docs/{PRIVACY,SUPPORT}.md` return HTTP 404. Public URLs must be supplied; changing repository visibility or publishing a site is not authorized.

### 2. Stop location services when a session actually ends

- [x] Add stateful recording services in `LocationSessionLifecycleTests.swift` and reproduce terminal GPS updates before fixing production code. The red run executed 140 tests with 50 expected assertions failing across the two new lifecycle suites (`/tmp/camera-gps-link-readiness/lifecycle-red-2.log`); original suites passed.
- [x] Correct terminal intent transitions in `CameraBLEManager*.swift`; `endLinkIntent()` clears persisted intent and disarms retry without bypassing pending-operation cleanup. Nine new manager tests passed, including bounded foreground failure and eligible background Bluetooth waiting.
- [x] Reconcile location lifetime in `CameraGPSLinkAppModel.swift`; snapshot-based stop guards prevent publication loops, and foreground-start reconciliation handles synchronous GPS publications against an old terminal state. Terminal states, repeated publications, background waiting, and explicit restart passed in `LocationSessionLifecycleTests`.
- [x] Extend lifecycle and health integration tests to preserve Stop/Cancel behavior, permission-pending cancellation, pairing independence, inactive-versus-background handling, and unexpected-loss alert semantics. The final local gate passed 152 unit tests and source-line checks (`/tmp/camera-gps-link-readiness/final-local-1.log`). Twelve app-model tests also cover synchronous service publications and suppress extra sends during Stop/background suspension. A prior launch failed with Simulator Busy; deleting only the dedicated test simulator restored execution.

### 3. Automate the existing verification gate

- [x] Adjust `justfile` so Swift and `xcodebuild` share the selected Xcode, with optional simulator OS/runtime inputs and result-bundle paths. `just ios-smoke`, `just ios-typecheck`, `just ios-lint-project`, `just source-line-check`, and `just ios-destinations` passed with the local Xcode 26.6 default (`/tmp/camera-gps-link-readiness/focused-static.log`). CLI dry-run verified the result-bundle argument.
- [x] Add `.github/workflows/ios-check.yml` for pull requests and pushes to the default branch, using read-only repository permissions, no signing secrets, bounded jobs, and cancellation of superseded runs; verify the workflow executes on a real PR without privileged `pull_request_target` execution.
- [x] Configure the workflow's fast job to run `just source-line-check-test`, `just source-line-check`, `just ios-smoke`, `just ios-typecheck`, `just ios-lint-project`, and `just ios-unit-test`; verify one hosted run passes every command without system prompts.
- [x] Configure isolated build/UI jobs to run the simulator build, unsigned Debug/Release/QUALIFICATION device builds, and `just ios-ui-test`; verify the combined jobs cover every `just check` component and retain test results or failure logs with finite artifact retention. Do not run unit and UI hosts concurrently against one simulator.
- [x] Document local-to-CI command mapping and observed toolchain requirements in `README.md`; verify the documented jobs match the workflow and record a successful run URL here. Repository-admin branch-protection changes are not required by this plan.

Section 3 evidence: [run 34680667403](https://github.com/narumiruna/camera-gps-link/actions/runs/34680667403), triggered by PR #17 at `42ac9ef`, passed all three jobs: `iOS / checks` (152 unit tests), `iOS / builds` (four builds), and `iOS / ui` (34 UI tests). Logs confirm the documented recipes ran. Artifacts `ios-checks-1`, `ios-builds-1`, and `ios-ui-1` contain logs and applicable `.xcresult` bundles, expiring on 2026-09-19. Permissions, pinned actions, isolated hosts, and absence of release/signing operations were reviewed.

### 4. Clarify what the camera can use while shooting

- [x] Add a persistent home-screen explanation for effective foreground-only mode in `GeotaggingHealthPresentation.swift` and `GeotaggingHomeView.swift`, stating that locking the phone or switching apps stops updates; verify its presence with alerts both on and off, and absence for enabled background mode, using view-state tests and `just ios-ui-test`.
- [x] Update cached-location presentation in `GeotaggingViewState.swift` and `GeotaggingHomeView.swift` so a fresh camera update with a stale, missing, invalid, or future phone fix explicitly says it is using the last sent location rather than implying a current fix; verify the first-packet gate, retained camera-cache age, low-accuracy distinction, and five-minute expiration with `just ios-unit-test`.
- [x] Extend `UITestFixtures.swift` and `ConnectionHealthUITests.swift` for the revised notices and cached-location presentation; verify Stop remains reachable, notices coexist, and VoiceOver labels, largest Dynamic Type, dark/increased-contrast appearance, and landscape pass `just ios-ui-test` without real permission prompts.
- [x] Update `docs/ios-app.md` and `docs/SUPPORT.md` to match the new visible status wording and foreground limitation; verify each documented state against the passing UI scenarios without promising per-photo GPS coverage.

Section 4 evidence: `just check` passed 152 unit tests and all 34 UI tests on 2026-09-12, including eight `ConnectionHealthUITests`. Initial UI failures exposed duplicate accessibility descendants, an inherited disclosure identifier, and largest-text contrast loss. Combined accessibility text, distinct preview targeting, a hard scroll edge on iOS 26+, and shorter summary copy resolved them; accessibility audits remain enabled without exclusions.

### 5. Provide support links and privacy-safe summaries

- [ ] Add Privacy Policy and Support links to `LinkSettingsView.swift` using the verified URLs; verify destinations through injected URL-opening tests and confirm both links remain reachable at the largest text size with `just ios-ui-test`, without applying draft settings or opening a browser in tests. Blocked by unavailable public URLs; no broken private URLs or placeholder links have been added.
- [x] Add the focused `DiagnosticsReport.swift` formatter for allowlisted metadata, exact recognized camera identity, connection state, and update age. Six `DiagnosticsReportTests` passed in the candidate unit gate, covering deterministic output, unknown fields, and malformed dates/metadata.
- [x] Add adversarial report tests for coordinate-bearing names/firmware, embedded control characters, UUIDs, addresses, raw payloads, long strings, and free-form errors. The formatter exports only canonical registry identity constants and never reads free-form log/error/name fields; all six report tests passed in the 150-test candidate unit gate (`/tmp/camera-gps-link-readiness/candidate-check.log`).
- [x] Add an explicit Copy Diagnostic Summary action and preview in `DiagnosticsView.swift`, separate from existing Copy Diagnostic Log. All three `DiagnosticsSummaryUITests` passed in the final local gate: empty-log output/copy feedback, no permission or session start, and largest-text dark-mode accessibility. Code review confirms local-only pasteboard storage with five-minute expiry and no network operation; the model test confirms summary reads never request services or permissions.
- [x] Update `docs/PRIVACY.md`, `docs/SUPPORT.md`, and the diagnostics warning to distinguish the allowlisted summary from potentially sensitive logs and on-screen coordinates. Reviewed against the six passing report tests and three passing copy-action UI tests; documents explicitly warn that the whole Diagnostics screen is not de-identified.

### 6. Qualify and promote only the exact public identity

- [ ] Record physical-test prerequisites here before any camera write: connected iPhone/iOS, A7C II firmware 2.01, signing access, source commit/build identifiers, and explicit authorization for the coordinate source and bounded test window. Blocked on 2026-09-12: `xcrun devicectl list devices` finds a paired available iPhone 16 Pro, but current camera firmware, session-specific coordinate/window authorization, and a new photo are not available. No physical-camera writes or registry promotion have been performed.
- [ ] Build and install a signed Release-optimized `QUALIFICATION` candidate from the locally and CI-verified code, with Background disabled in settings; record evidence that `QUALIFICATION`, not DEBUG or public policy, is active and that the exact model/firmware/protocol/fingerprint/95-byte target is enforced.
- [ ] Run the authorized foreground session, capture a new JPEG or HEIF after an acknowledged DD11 and before Stop, and verify GPS EXIF plus capture-time bounds using the maintained SonyGeoTag tooling; record sanitized results, tool version, coordinate tolerance, and private artifact references in `docs/compatibility/ilce-7cm2-2.01.md`. Do not commit precise coordinates or source photos from this new run.
- [ ] Verify Stop completes DD31 disable, DD30 unlock, and DD01 notification cleanup on that candidate; record operation order, cleanup result, and observed stopped location updates in the same evidence document. Failed or missing cleanup blocks promotion.
- [ ] Promote only the proven entry in `SonyReleasePolicy.swift` and align `docs/sony-camera-compatibility.md` plus the evidence document; verify `SonyReleasePolicyTests.swift` accepts that exact identity and still rejects different models, firmware, protocols, fingerprints, pairing endpoint shapes, and DD21 packet sizes before application writes via `just ios-unit-test` and both unsigned Release/QUALIFICATION builds.
- [ ] Validate a signed public Release build after promotion on the same authorized hardware, renewing write authorization when needed; record a successful first update, a fresh-photo EXIF check, clean Stop, and foreground-only suspension in the evidence document. Keep public background disabled and record the tested build/commit without submitting to the App Store.

## Rollback / Recovery

- If lifecycle changes suppress legitimate retry or alter cleanup/health alerts, revert the focused change and leave its regression tests and completion items unresolved; do not bypass cleanup or convert foreground failures into unlimited reconnects.
- If CI infrastructure is unavailable, retain `just check` as the local gate and leave hosted-run evidence open; do not report local success as CI success.
- If a report leaks a sensitive fixture, disable the new summary action until its allowlist tests pass; do not relax the privacy requirement to preserve arbitrary log output.
- If qualification or public Release validation fails, remove any newly promoted public entry and restore the documented unverified status. Do not add an override, enable background operation, or claim release readiness. Camera recovery after incomplete cleanup follows the existing documented manual procedure before another separately authorized write attempt.

## Completion Checklist

- [x] Terminal-location regression tests pass, repeated publications are idempotent, and authorized background retry plus existing cleanup/health-alert behavior remain covered by passing tests. Final local gate: 152 unit tests, zero failures.
- [x] `just check` passes on the final implementation commit; source-size checks pass and local toolchain/test results are recorded here. Repeated on committed `42ac9ef` on 2026-09-12: smoke, typecheck, project/source lint, four builds, 152 unit tests, and 34 UI tests, using Xcode 26.6 (`17F113`), Swift 6.3.3, and iOS Simulator 26.5 (`23F77`). Log: `/tmp/camera-gps-link-readiness/committed-gate.log` (exit 0; commit recorded in `committed-gate.sha` alongside it). Full diff review, `git diff --check`, strict Swift formatting, and `actionlint` 1.7.12 passed. GitHub reports the commit signature as verified; local verification against the configured public key also passed.
- [x] Every required workflow job passes on that implementation commit, with a hosted run URL and retained verification evidence; no signing secrets or physical-camera access are needed by CI. See section 3. Subsequent plan-evidence-only commits do not change the tested implementation; current-head checks are visible in PR #17.
- [ ] Home-screen limitations, cached-location wording, support links, and safe-summary copy behavior pass their unit/UI checks, and the related user/privacy documents match the implementation. Home/summary behavior and matching documents pass; public support links remain blocked by section 1.
- [ ] Qualification and promoted public Release evidence proves fresh-photo GPS EXIF and clean Stop for the exact A7C II identity; unsupported identities still fail closed and public background remains disabled.
- [ ] All execution tasks have passing evidence, prerequisites are resolved, and the handoff identifies the tested build plus remaining out-of-scope App Store/background work. Only then delete this plan and report its path; hardware or CI blockers do not count as completion.
