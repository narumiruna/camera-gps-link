# Multi-model Sony Location Support Plan

## Goal

Expand the Python tools in `src/` and the iOS app from A7C II-only validation to capability-driven Sony BLE location support, qualifying models in this order:

1. Sony A7 III (`ILCE-7M3`), including the legacy DD11 flow when a camera advertises protocol `< 65` and lacks DD30/DD31.
2. Sony A7 IV (`ILCE-7M4`), then Sony A6700 (`ILCE-6700`), both expected but not assumed to use the modern A7C II flow.
3. Sony A7R V (`ILCE-7RM5`), A7S III (`ILCE-7SM3`), A1 (`ILCE-1`), ZV-E1, and ZV-E10 II, each qualified independently rather than through a family-wide claim.

Success means protocol behavior is selected from completed service/characteristic discovery, usable GATT properties, advertisement protocol version, and DD21 data rather than model-name assumptions; A7C II behavior remains unchanged; and each named model is labeled verified only after both Python and iOS foreground writes produce correct GPS EXIF on new photos.

## Context

- A7C II is the only historical end-to-end baseline with accepted 95-byte DD11 writes and correct photo EXIF; runtime confidence remains experimental until post-refactor requalification; see `docs/a7c2-ble-map.md`.
- `src/sonygeotag/sony_location.py` currently attempts DD30 and DD31 unconditionally, so a legacy camera without those characteristics cannot sync.
- `CameraBLEManager.maybeBeginLocationSetup()` currently resolves too early from UUID presence and requires DD30, DD31, and DD11, so it cannot run a legacy session or detect incomplete characteristic discovery safely.
- Python accepts repeated `--target` values, but `DEFAULT_TARGETS` and `justfile` defaults are A7C II-specific.
- iOS recognizes Sony manufacturer data, but its displayed `targetName` is fixed to `ILCE-7CM2`, it discovers only DD/EE services for location setup, and it does not expose detected firmware or support confidence.
- iOS currently queues EE01 whenever that characteristic exists, and `just location-write` always passes `--vendor-pair-init`; both behaviors must be separated from ordinary location sessions because EE01 outside pairing state can disconnect a camera.
- `CameraBLEManager.swift` is already 898 lines; new capability, session-planning, identity, and test-seam logic must live in separate source files so every program source remains below 1000 lines.
- `docs/third-party-sony-protocol-reliability.md` establishes CameraSync source as the preferred modern-flow reference and `ILCE7M3ExternalGps/PROTOCOL_EN.md` as document-only legacy context.

## Architecture

### Capability resolution

- Add equivalent pure capability resolvers in Python and Swift.
- Resolve only after all requested Sony services have completed characteristic discovery.
- Give each resolver the advertisement protocol version and discovered descriptors containing service UUID, characteristic UUID, and properties.
- Require characteristics to belong to the expected DD service and have these properties before a profile is executable:
  - DD11: write-with-response; write-without-response-only remains unsupported until separately researched on physical hardware.
  - DD21: read.
  - DD30 and DD31 for modern flow: write-with-response.
  - DD01 when used: notify or indicate.
  - DD32/DD33 when used: read.
- Return a `modern`, `legacy`, or `unsupported` profile with a diagnostic reason:
  - `modern`: DD11, DD21, DD30, and DD31 have required properties and protocol is `>= 65`; optional DD01/DD32/DD33 are recorded separately.
  - `modern experimental`: the complete modern shape exists but protocol version is unknown.
  - `legacy`: protocol is known to be `< 65`, DD11 and DD21 have required properties, and both DD30/DD31 are absent.
  - `unsupported/inconsistent`: DD11 or readable DD21 is missing, only one control exists, protocol `>= 65` lacks controls, protocol `< 65` unexpectedly has controls without model-specific evidence, an unknown-version camera has only the legacy shape, discovery is incomplete, or required properties are wrong.

### Session planning and safety

- Keep packet negotiation independent of session style: automatic writes accept only evidence-backed DD21 framing—exactly 6 or 7 bytes, prefix `06 10 00 9c`, only known flag bit `0x02` at byte 4, and zero reserved tail bytes; bit `0x02` selects 95 bytes and a clear bit selects 91 bytes.
- Treat another length, prefix, unknown flag bit, nonzero reserved byte, missing value, or read failure as negotiation failure; capture a sanitized value for research but never send DD11 until model-specific evidence extends the accepted framing rules.
- Preserve `encode-location --no-timezone` for offline packet generation, but remove/reject `send-location --write --no-timezone`; real writes always follow validated DD21.
- Remove `send-location --write --no-unlock`; every real session attempts bounded cleanup, and no CLI option may suppress compensation after success, failure, cancellation, or timeout.
- Complete identity/profile discovery before any DD01 subscription or application-level GATT write.
- Require experimental approval before any notification subscription, EE01, DD30, DD31, or DD11 action:
  - Python first performs read-only discovery and exits with the detected identity/profile unless the caller repeats the command with `--allow-experimental`.
  - iOS pauses in an explicit confirmation state before setup.
  - Approval is scoped to normalized model, readable firmware, protocol version, full resolved execution profile, and action purpose; Python refuses reusable approval when firmware is unreadable, while iOS permits only volatile session approval.
  - A registry entry marked unsupported blocks writes even if generic characteristics look executable.
- Keep EE01 in a separate explicitly selected pairing action; ordinary verified and experimental location sessions never enqueue it.
- Track DD30 and DD31 confirmed and possibly-applied states independently; permit DD11 only after confirmed setup, but compensate any control whose write was dispatched because an acknowledgement can be lost after the camera commits it:
  - DD30 succeeds and the DD31 write fails or times out: attempt DD31=`00`, then DD30=`00`.
  - Both succeed and DD21 fails/cancellation occurs: write DD31=`00`, then DD30=`00`.
  - Legacy: never write DD30/DD31 setup or cleanup.
  - Disconnect before compensation is possible: record an explicit incomplete-cleanup diagnostic.

### Ownership and evidence

- Keep model names out of protocol branching; use a separate compatibility registry only for user-visible `verified`, `experimental`, or `unsupported` confidence and evidence links.
- Add focused Python and Swift profile/session-plan modules; keep BLE execution/reconnect ownership in `sony_location.py` and `CameraBLEManager` behind injectable fakeable transport seams.
- Extend iOS read-only discovery to the CC service for CC0A firmware and CC0B model; fall back to the advertised/peripheral model name with unknown firmware when those reads are unavailable.
- Persist the last validated model, firmware, protocol version, and profile privately with the remembered peripheral so direct reconnect/restoration can recover advertisement context only when fresh CC identity and discovered descriptors still match; otherwise downgrade to unknown/experimental and require approval before any subscription/write.
- Preserve the current single-camera/remembered-peripheral design; multi-camera management is not part of this expansion.
- Store only sanitized evidence under `docs/compatibility/`: no peripheral IDs, Bluetooth addresses, credentials, opaque manufacturer tails, unknown raw values, or photo files.
- Retain peripheral identifiers only in private reconnect storage; remove them and opaque manufacturer tails from committed documentation, logs, diagnostics UI, and exported evidence.

## Non-Goals

- Do not infer location support from FF00 Bluetooth-remote compatibility.
- Do not claim all Sony Alpha or ZV cameras are supported because one family member works.
- Do not change DD11 field encoding unless a model capture proves a protocol difference.
- Do not alter background reconnect or low-power policy; new models receive foreground qualification first, and background support remains separately unverified.
- Do not run `just location-write`, another Python write, or an iOS camera write while executing this plan unless the user separately authorizes that physical test and supplies or approves the coordinates.

## Assumptions

- A7 III firmware may expose either a legacy or modern profile; model name alone will not force legacy behavior.
- A7 IV and A6700 are modern-flow candidates, but remain experimental until their actual identity, advertisement, GATT map/properties, DD21 value, operations, and EXIF are observed.
- ZV scope initially means ZV-E1 and ZV-E10 II because those are the models in the checked-in compatibility reference; another ZV model requires its own matrix row and qualification evidence.
- Camera-native JPEG or HEIF can provide repeatable EXIF qualification; the user explicitly selected HEIF for the A7C II regression, while RAW support remains out of scope.

## Unknowns

- Which target cameras and firmware versions will be physically available.
- Whether an available A7 III still advertises protocol `< 65`; if not, legacy support can be implemented and fixture-tested but remains physically unverified unless the user explicitly accepts that deferral.
- Whether DD01 is required, optional, or behaviorally different on each model.
- Whether any target returns a DD21 layout that differs from the observed A7C II response.

## Risks

- Resolving from partial discovery or UUIDs without properties could write to a misidentified/incompatible characteristic; completed discovery and strict property checks must fail closed.
- Modern DD21 is read after DD30/DD31 in the validated flow, so negotiation failure can occur after setup writes; per-operation acquisition tracking and compensation are required.
- A model can change behavior across firmware versions; verification and consent keys must include firmware when known and protocol version/profile always.
- Refactoring the working A7C II flow can regress foreground or background reconnection; run full local checks and an explicitly authorized A7C II foreground regression before any experimental-model write.
- A generic Sony scan may find the wrong nearby camera; continue preferring the remembered peripheral and show resolved identity before experimental approval.
- Raw BLE captures may contain stable identifiers, credentials, or unknown sensitive payloads; use the sanitized snapshot path and never commit raw captures.

## Plan

### Phase 1 — Define the compatibility and safety contract

- [x] Add `docs/sony-location-profile-spec.md` with a truth table for completed discovery, service ownership, required properties, protocol-version combinations, DD21 valid 6/7-byte framing plus wrong-length/prefix/flag/reserved/read-error cases, support-registry overrides, experimental approval, setup, compensation, and cleanup; verify every row has one deterministic profile and permitted operation set.
- [x] Add `docs/sony-camera-compatibility.md` with model, firmware, advertisement version, discovered profile, DD21 bytes/packet size, Python/iOS status, background status, and evidence-link columns; record only A7C II as a historical baseline while keeping all runtime rows unverified/experimental pending post-refactor qualification.
- [x] Add `src/sonygeotag/sony_capabilities.py` with pure descriptor/profile and session-plan types; verify all truth-table rows in `tests/test_sony_capabilities.py`, including wrong service, wrong properties, incomplete discovery, unknown version, and unsupported-registry cases.
- [x] Add Swift equivalents such as `SonyLocationProfile.swift` and `SonyLocationSessionPlan.swift`; add them to the app target and test target in `project.pbxproj`, include them explicitly in `just ios-smoke`, and verify the same truth-table cases in XCTest/smoke tests.
- [x] Add a `source-line-check` recipe covering Python and Swift program sources, include it in `just check`, and verify it fails on a temporary >1000-line fixture but passes the repository.

### Phase 2 — Build safe read-only evidence and EXIF tooling

- [x] Add a strict read-only `compatibility-snapshot` Python command that scans/connects/discovers and reads only approved identity/DD21 fields, emits model, firmware, protocol version, relevant service/characteristic properties, and DD21 bytes, and excludes addresses, peripheral IDs, credentials, unknown payloads, and manufacturer tails; verify fake-client tests observe no notify or write calls and JSON redaction is stable.
- [x] Add a local JPEG/HEIF EXIF verification command/recipe using locked runtime dependencies, accepting an image path, expected coordinates, and an ISO-8601 DD11 success/not-before timestamp, outputting numeric GPS/date JSON, and failing when coordinates differ by more than `0.0001°` or capture time is not strictly later; prefer DateTimeOriginal with its EXIF offset, fall back to GPS UTC when needed, otherwise require an explicit camera timezone, and test JPEG/HEIF positive, missing-GPS, missing/ambiguous-time, stale-time, and out-of-tolerance fixtures.
- [x] Define `docs/compatibility/<model>-<firmware>.md` evidence format containing sanitized snapshot, platform, approved coordinate, DD11 success/not-before time, unambiguous JPEG/HEIF capture time after DD11, packet size, sanitized operation order, EXIF verifier output, and result; do not commit the evidence image or raw BLE log.
- [x] Remove or redact the CoreBluetooth identifier and opaque manufacturer tail already present in `docs/a7c2-ble-map.md`, remove peripheral UUIDs from BLE logs and `DiagnosticsView`, and add sanitized-export tests proving private reconnect identifiers never appear in documentation/exported diagnostics.

### Phase 3 — Apply profiles to Python

- [x] Refactor `src/sonygeotag/sony_location.py` behind an injectable BLE transport to wait for completed discovery, resolve strict descriptors, and execute modern or legacy session plans; verify exact operation order and forbidden-write absence with fake transports.
- [x] Require evidence-backed 6/7-byte DD21 framing before DD11, remove real-write `--no-timezone` and `--no-unlock` overrides, and track successful DD30/DD31 operations independently; verify every malformed framing variant, DD30-success/DD31-failure, both-success/DD21-failure, cancellation/timeout at every operation, disconnect-without-cleanup, legacy, and unsupported cases.
- [x] Remove vendor pairing initialization from ordinary location flow, keep it as a distinct explicitly authorized pairing action, and change `just location-write` to omit `--vendor-pair-init`; verify ordinary modern, legacy, unsupported, and experimental sessions never write EE01.
- [x] Add Python experimental gating: a first `--write` request on an unverified identity performs read-only discovery and exits with the normalized identity/profile, while `--allow-experimental` permits the repeated command; verify unsupported registry entries still block and no approval path bypasses DD21/property checks.
- [x] Extend camera-info/location text and JSON with model, firmware, protocol version, profile, DD21 mode, packet size, confidence, approval requirement, and cleanup diagnostics; verify existing fields remain compatible and CLI tests cover each state.
- [x] Keep A7C II default targets for backward compatibility and document explicit `--target`/`just` examples for every candidate; verify scan/GATT/info/snapshot commands are read-only and `send-location` remains dry-run without `--write`.

### Phase 4 — Apply profiles to iOS

- [x] Add read-only CC0A/CC0B identity discovery and a private validated identity record; verify scanned sessions refresh advertisement protocol data, direct reconnect/restored sessions reuse it only when current CC identity and descriptors match, mismatches invalidate it before subscriptions/writes, and diagnostics correlate sanitized model, firmware or unknown, protocol, profile, DD21 bytes, packet size, and operation order.
- [x] Refactor `CameraBLEManager` to wait for complete requested-service discovery, resolve strict descriptors, and execute a `SonyLocationSessionPlan` through an injectable executor; verify manager-to-plan integration rather than only pure planner output.
- [x] Remove unconditional EE01 from `maybeBeginLocationSetup()` and expose pairing initialization as a distinct user-selected pairing state/action; verify normal connections cannot enqueue EE01.
- [x] Add the pre-write experimental state keyed by model, firmware, protocol, and profile; verify confirmation occurs before DD01 subscription or any application write, cancel has no GATT side effect, unknown firmware approval lasts only for the current session, and unsupported registry entries cannot continue.
- [x] Track confirmed and possibly-applied DD30/DD31 state independently and implement compensation for failure, cancellation, timeout, and disconnect diagnostics; mirror the Python partial-setup test matrix in XCTest.
- [x] Update view state and diagnostics to show detected camera identity, verified/experimental/unsupported confidence, modern/legacy profile, packet size, pairing state, cleanup failure, and actionable retry/cancel behavior instead of a fixed A7C II target; verify loading, confirmation, unsupported, connected, disconnect, and retry UI states without relying on color alone.
- [x] Keep `CameraBLEManager.swift` below 1000 lines by extracting profile, identity, planning, and executor seams; verify `just source-line-check` and `just check`.

### Phase 5 — Re-qualify A7C II before expansion

- [x] Run the sanitized A7C II compatibility snapshot and confirm its resolved modern profile, DD characteristic properties, seven-byte DD21 value, and 95-byte mode match `docs/a7c2-ble-map.md`; perform no writes in this task.
- [x] With separate explicit user authorization and approved coordinates, run one bounded Python A7C II foreground session, capture a new HEIF while DD11 updates remain active, and record passing EXIF evidence with the standard tool.
- [ ] With separate explicit user authorization and approved current-phone/test coordinates, repeat the foreground write through iOS, capture a separate new JPEG or HEIF image during the active session, and record passing EXIF evidence; do not begin A7 III writes until both A7C II regressions pass.

### Phase 6 — Qualify A7 III

- [ ] Capture a sanitized read-only A7 III snapshot, recording model, firmware, advertisement protocol version, DD service ownership/properties, and DD21 bytes; verify the resolver selects legacy only for a known `< 65` complete legacy shape and otherwise follows observed capabilities.
- [ ] Compare the observed profile with `third_party/ILCE7M3ExternalGps/PROTOCOL_EN.md`, add only useful new source notes to `third_party/references.md`, and resolve any mismatch before an experimental write.
- [ ] With separate explicit user authorization, run one bounded Python A7 III write using `--allow-experimental` and approved coordinates, then record new-photo EXIF, packet size, and operation order for that firmware/profile.
- [ ] With separate explicit user authorization, repeat through iOS after reviewing the experimental identity/profile confirmation, then record a separate new-photo EXIF result; promote only that exact A7 III firmware/protocol/profile after both platforms pass.
- [ ] If protocol-`< 65` hardware is unavailable, keep legacy physical status unverified and obtain explicit user acceptance of the documented deferral before plan completion; fixture coverage alone must not produce a verified legacy label.

### Phase 7 — Qualify A7 IV, then A6700

- [ ] Complete the full A7 IV sequence—sanitized snapshot, profile review, separately authorized Python write/EXIF, and separately authorized iOS write/EXIF—before promoting its exact firmware/profile.
- [ ] After A7 IV is complete, run the same full sequence independently for A6700; do not inherit A7 IV or A7C II status even if the modern profile matches.
- [x] Re-run the automated A7C II modern and A7 III legacy/modern fixtures after both additions; verify registry changes do not alter capability resolution or experimental gating.

### Phase 8 — Expand the verified matrix

- [ ] Qualify A7R V, A7S III, and A1 one at a time using the same sanitized snapshot → profile review → separately authorized Python write/EXIF → separately authorized iOS write/EXIF sequence; create separate firmware/profile rows and do not batch-promote the Alpha family.
- [ ] Qualify ZV-E1 and ZV-E10 II one at a time with the same sequence; keep every other ZV model unverified until it receives an explicit row and independent evidence.
- [x] Update README/user-facing support text to distinguish exact verified model+firmware profiles, experimental capability matches, unsupported registry entries, and unverified background behavior; verify no family-wide claim exceeds the compatibility matrix.

### Phase 9 — Final verification and handoff

- [x] Run `just check`; record Python lint/type/test, iOS smoke/typecheck/project lint/build/unit/UI results, source-line gate, and leave any unavailable physical-model or legacy-profile checks explicitly open unless the user accepts a documented deferral.
- [x] Audit every unsupported/pre-approval path for zero subscriptions/application writes, every post-setup failure for bounded compensation, every evidence artifact for redaction, and the final diff with `git diff --check`.
- [ ] Review the compatibility matrix against sanitized snapshots and per-platform EXIF evidence, then archive this plan only after every named model is complete and any unavailable A7 III legacy-hardware validation has an explicit accepted deferral.

## Verification Record

- 2026-08-09: initial `just check` passed Python lint/type/114 tests, Swift smoke/typecheck/project lint/build, 51 iOS unit tests, 17 iOS UI tests, and the 52-file source-line gate.
- 2026-08-09: after HEIF support and the active-window hardening, `just check` passed Python lint/type/120 tests, Swift smoke/typecheck/project lint/two builds, 51 iOS unit tests, 17 iOS UI tests, and the 52-file source-line gate.
- 2026-08-09: a fresh Python 3.12 virtual environment installed the built wheel with runtime dependencies and `sonygeotag --help` exposed `verify-exif` successfully.
- 2026-08-09: `git diff --check` passed and independent reviewers audited approval, timeout, compensation, reconnect intent, readiness, and diagnostics-redaction paths.
- 2026-08-09: the initial default sanitized A7C II snapshot returned `No target found`; after the camera became available and stale host/camera pairings were cleared, fresh pairing succeeded. The captured `ILCE-7CM2` firmware `2.01`, protocol `101` snapshot resolved modern service-owned DD11/DD21/DD30/DD31 properties and `06 10 00 9c 02 00 00` / 95-byte mode, matching the historical baseline; see `docs/compatibility/ilce-7cm2-2.01.md`.
- 2026-08-09: after explicit authorization for `25.033964, 121.564468`, the A7C II Python modern session accepted three 95-byte DD11 updates during a 60-second active window, completed DD31/DD30 cleanup, displayed the matching DMS coordinate on camera, and a camera-native HEIF passed the standard verifier with capture time `2026-08-09T23:19:05+08:00`; see the sanitized evidence file. iOS and other-model physical qualifications remain open.
- 2026-08-10: final review/hardening made registry matching exact (no nil-field wildcards), rejected duplicate GATT UUID ambiguity, accepted NUL-padded iOS identity values, terminally disconnected unsupported profiles, rejected stale CoreBluetooth callbacks, failed closed when Bluetooth disappears with possible controls, preserved incomplete-cleanup diagnostics, normalized EXIF fractional-second rollover, and reset the dedicated simulator between XCTest hosts. `just check` passed 123 Python tests, 58 iOS unit tests, 17 iOS UI tests, both iOS builds, smoke/type/project checks, and the 52-file source-line gate.

## Completion Checklist

- [x] Python and Swift select modern, legacy, or unsupported behavior only after complete discovery with matching service/property/version truth-table coverage.
- [x] Only evidence-backed 6/7-byte DD21 framing produces DD11; every wrong-length/prefix/flag/reserved/read-error case blocks DD11, and partial modern setup performs only required compensation in verified order.
- [x] Ordinary and experimental location sessions never send EE01; pairing initialization requires a separate explicit action.
- [x] Unsupported and pre-approval experimental paths perform no notification subscription or application-level GATT write and present an actionable reason.
- [ ] A7C II retains its modern 95-byte behavior and passes explicitly authorized Python plus iOS foreground EXIF regression before another model is written.
- [ ] A7 III has exact firmware/profile Python and iOS EXIF evidence; protocol-`< 65` legacy status is either physically verified or explicitly accepted as an unverified deferral.
- [ ] A7 IV and A6700 each have independent sanitized snapshots and Python/iOS EXIF evidence.
- [ ] A7R V, A7S III, A1, ZV-E1, and ZV-E10 II each have independent compatibility rows and Python/iOS EXIF evidence.
- [x] Diagnostics and documentation show sanitized model/firmware, protocol, profile, DD21 mode, packet size, confidence, approval, operation order, and cleanup status without peripheral IDs, addresses, manufacturer tails, or other sensitive BLE data.
- [x] Scanned, direct-reconnect, and CoreBluetooth-restored iOS sessions resolve or invalidate persisted protocol context safely before any subscription/write.
- [x] Real Python writes expose neither packet-mode nor cleanup-suppression overrides; DD21 controls packet size and bounded cleanup is mandatory.
- [x] Every Python and Swift program source remains below 1000 lines under an automated `just check` gate.
- [ ] `just check` and `git diff --check` pass, required deferrals are explicitly accepted, and the completed plan is archived.
