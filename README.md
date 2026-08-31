# SonyGeoTag

Sony Alpha BLE geotagging tools plus an iOS MVP for keeping a camera's GPS cache updated from phone location data.

Historical verified baseline: Sony A7C II / `ILCE-7CM2` firmware `2.01`, protocol `101`, modern 95-byte profile. Other listed models are unverified; only a camera whose discovered shape is executable is labeled experimental. Exact post-refactor status is tracked in [`docs/sony-camera-compatibility.md`](docs/sony-camera-compatibility.md).

## What this repo contains

- **Python CLI (`sonygeotag`)** for BLE discovery, GATT inspection, notification logging, and Sony `DD11` location-packet encoding/sending.
- **Camera GPS Link iOS app (`ios/CameraGPSLink`)** built with SwiftUI, CoreBluetooth, and CoreLocation for foreground/background location linking.
- **Protocol notes** for the observed A7C II BLE services and location flow in `docs/a7c2-ble-map.md`.

## Safety first

Most probe commands are read-only apart from normal BLE connection/subscription behavior.

`camera-info` is stricter: it only scans, connects, discovers services, reads characteristics, and disconnects. It never calls an application-level GATT write or subscribes to notifications. `--pair` may ask the OS to establish BLE security, but does not authorize Sony vendor writes.

`send-location` is a dry run unless `--write` is present. A real request completes identity and characteristic discovery first, selects a capability-driven modern or legacy profile, validates strict `DD21`, and always compensates controls it acquired. Experimental identities stop read-only on the first request; repeat with `--allow-experimental` only after reviewing the detected model, firmware, protocol, and profile. Do not write arbitrary payloads to the camera.

## Requirements

- Python 3.12+
- [`uv`](https://docs.astral.sh/uv/) for Python dependency/runtime management
- BLE-capable macOS host for Python probing
- Full Xcode installation for the iOS app
- Physical iPhone for real BLE and background-location validation
- Sony camera in the appropriate Bluetooth/location-link state; first write tests may require camera pairing mode

## Quick start

```bash
uv sync
uv run sonygeotag --help
just --list
```

Scan for the target camera:

```bash
uv run sonygeotag scan --target ILCE-7CM2 --timeout 15
```

Read a decoded, strictly read-only camera snapshot:

```bash
uv run sonygeotag camera-info --target ILCE-7CM2 --pair
uv run sonygeotag camera-info --target ILCE-7CM2 --pair --json
```

Open a live, read-only Textual dashboard (press `q` or `Ctrl+C` to quit):

```bash
uv run sonygeotag monitor --target ILCE-7CM2 --pair
```

Encode a Sony `DD11` GPS packet without touching BLE:

```bash
uv run sonygeotag encode-location --lat 35.681236 --lon 139.767125
```

Dry-run the location flow without writing to the camera:

```bash
uv run sonygeotag send-location --lat 35.681236 --lon 139.767125
```

## Read-only camera information

`camera-info` reads every characteristic currently marked `read` in one BLE session. Known payloads are decoded and grouped into identity, battery, storage, camera status, network, location, and pairing information. State-dependent failures such as Sony `0x90`/`0x9D`, insufficient encryption, and timeouts remain attached to the affected characteristic rather than failing the whole snapshot.

```bash
# Human-readable, sensitive data redacted
uv run sonygeotag camera-info --target ILCE-7CM2 --pair

# Stable schema-v1 JSON, suitable for later iOS parity work
uv run sonygeotag camera-info --target ILCE-7CM2 --pair --json

# Add public raw payloads; unknown/sensitive raw remains redacted
uv run sonygeotag camera-info --target ILCE-7CM2 --pair --json --include-raw

# Explicitly reveal network values, identifiers, and unknown raw payloads
uv run sonygeotag camera-info --target ILCE-7CM2 --pair --json --include-raw --show-sensitive
```

Sensitive values include the CoreBluetooth address, SSID, BSSID, Wi-Fi password, FTP profile names, opaque identifiers, and unknown proprietary payloads. Avoid saving or sharing output produced with `--show-sensitive`. The command never activates Wi-Fi; credentials are only readable if the camera is already in a state that exposes them.

JSON schema v1 contains `schema_version`, `captured_at`, redacted `device` metadata, parsed advertisement fields, a summary, decode-status counts, and one result per readable characteristic. Decode statuses are `decoded`, `partial`, `unknown`, `unavailable`, and `error`; confidence is reported separately as `verified`, `referenced`, `tentative`, or `unknown`.

## Live camera monitor

The `monitor` command keeps one BLE connection open and polls a focused set of readable characteristics. It displays battery, storage, recording/streaming, Wi-Fi, remote-control availability, and location-link state. If the connection drops, it returns to scanning automatically. It never performs an application-level GATT write or notification subscription.

```bash
# Poll every two seconds until q or Ctrl+C
uv run sonygeotag monitor --target ILCE-7CM2 --interval 2 --pair

# Run for 60 seconds, useful for scripted checks
uv run sonygeotag monitor --target ILCE-7CM2 --duration 60 --pair
```

You can also launch it with `just ble-monitor` when `just` is installed.

## BLE probe commands

Dump services and characteristics:

```bash
uv run sonygeotag gatt-dump --target ILCE-7CM2 --timeout 10
uv run sonygeotag list-services --target ILCE-7CM2
```

Read readable characteristics:

```bash
uv run sonygeotag read-values --target ILCE-7CM2
uv run sonygeotag read-values --target ILCE-7CM2 --pair
uv run sonygeotag read-values --target ILCE-7CM2 --characteristic cc06 --json
```

Subscribe to notify characteristics and stream packets as JSONL:

```bash
uv run sonygeotag notify-log --target ILCE-7CM2 --duration 30
uv run sonygeotag notify-log --target ILCE-7CM2 --duration 30 --pair
uv run sonygeotag notify-log --target ILCE-7CM2 --characteristic cc03 --text
```

Save JSON/JSONL logs for diffs:

```bash
uv run sonygeotag scan --json > scan.json
uv run sonygeotag gatt-dump --json > gatt.json
uv run sonygeotag read-values --json > read-values.json
uv run sonygeotag notify-log --duration 60 > notify-log.jsonl
```

## Writing GPS to the camera

Only use this when you intentionally want to update the camera's cached GPS position:

```bash
uv run sonygeotag send-location \
  --target ILCE-7CM2 \
  --lat 35.681236 \
  --lon 139.767125 \
  --write \
  --duration 60 \
  --pair
```

Useful notes:

- The app/CLI proactively writes `DD11`; capture photos while the location session is active. A bounded CLI session disables DD31 and unlocks DD30 on exit, so a packet accepted just before cleanup does not prove a later photo will retain that fix.
- Strict 6/7-byte `DD21` determines whether to use the 95-byte timezone-capable packet or the 91-byte packet; malformed or unreadable values block `DD11`.
- Cleanup cannot be disabled. Modern sessions compensate only controls that were acquired; legacy sessions never touch `DD30`/`DD31`.
- Ordinary and experimental location sessions never write `EE01`. `sonygeotag pair-init` is a separate dry-run-by-default pairing action and must run while the camera is visibly waiting for pairing, after the OS Bluetooth bond has completed. Finish pairing, return to shooting mode, and then start an ordinary location session.
- Successful A7C II baseline tests accepted the modern flow and wrote GPS EXIF for newly captured photos. A fresh cross-platform regression remains required after this refactor.

For an unverified camera, first capture a read-only snapshot:

```bash
uv run sonygeotag compatibility-snapshot --target ILCE-7M3 --pair
uv run sonygeotag compatibility-snapshot --target ILCE-7M4 --pair
uv run sonygeotag compatibility-snapshot --target ILCE-6700 --pair
```

The same command accepts `ILCE-7RM5`, `ILCE-7SM3`, `ILCE-1`, `ZV-E1`, or `ZV-E10M2`. A first experimental `send-location --write` remains read-only and prints an approval key. After separate authorization and review, repeat with both `--allow-experimental --approval-key <printed-key>`; a key cannot authorize another model, firmware, protocol, or profile.

For explicit first-time pairing initialization, first complete the OS Bluetooth bond, leave the camera on its pairing screen, and run `pair-init`. The first request is dry-run/read-only and prints an identity/profile-scoped key when experimental approval is required:

```bash
uv run sonygeotag pair-init --target ILCE-7CM2 --pair --write
```

Review the identity/profile, repeat with `--allow-experimental --approval-key <printed-key>`, return the camera to shooting mode, and use the ordinary `send-location` command. Pairing and location remain separate sessions.

Verify a newly captured JPEG or HEIF image without committing the photo:

```bash
uv run sonygeotag verify-exif \
  --photo new-photo.jpg \
  --lat 35.681236 \
  --lon 139.767125 \
  --not-before 2026-08-09T12:34:56+09:00
```

## iOS app

The SwiftUI/CoreBluetooth/CoreLocation app lives in:

The first public iOS App Store release is scoped only to Sony Alpha 7C II (`ILCE-7CM2`).
See the accepted [`A7C II-only release plan`](docs/plans/2026-08-31_ios-a7c2-only-app-store-release-plan.md) for the runtime policy, physical qualification, metadata, and review gates.

```bash
ios/CameraGPSLink
```

Open with full Xcode:

```bash
open ios/CameraGPSLink/CameraGPSLink.xcodeproj
```

The iPhone interface is organized around the shooting workflow:

- **Start Geotagging**, visible connection stages, foreground cancellation, bounded waits, and actionable Retry.
- Detected model/firmware/protocol/profile resolution plus an explicit experimental confirmation before any subscription or write.
- **Ready to Geotag** only after the camera receives the first successful location update in the current session.
- A compact Readiness summary for camera, iPhone location, and the last camera update.
- Applied Link Settings for While Open/Background availability and Battery Saver/Best Accuracy updates, with a concrete preview and side-effect-free cancellation.
- Explicit partial-state recovery when Background is selected without Always Location permission.
- A separate Diagnostics screen preserving sanitized DD11/DD21, profile, confidence, pairing, cleanup, reconnect, location, and bounded debug-log details with no exported peripheral identifier.
- CoreBluetooth restoration/pending reconnect and best-effort Background App Refresh, subject to iOS background limits.

See `ios/CameraGPSLink/README.md` for the complete workflow, settings effects, permission states, diagnostics privacy, testing, and platform limitations.

## Development

Common commands are defined in `justfile`:

```bash
just --list
just py-check
just ios-check
just check
```

Useful iOS commands:

```bash
just ios-open
just ios-smoke
just ios-typecheck
just ios-unit-test
just ios-ui-test
just ios-test
just ios-build-sim
just ios-build-device-nosign
```

## Project layout

```text
src/sonygeotag/          Python CLI and protocol helpers
tests/                   Python tests
docs/                    Protocol notes and implementation plans
ios/CameraGPSLink/          SwiftUI iOS app and smoke test
justfile                 Local command shortcuts
```

## Limitations

- The exact A7C II row is historical evidence only; runtime confidence remains experimental until its post-refactor Python/iOS foreground regression receives explicit physical-write authorization and passes.
- A7 III, A7 IV, A6700, A7R V, A7S III, A1, ZV-E1, and ZV-E10 II remain experimental/unverified until the compatibility matrix links independent evidence.
- BLE behavior may differ across Sony models and firmware versions.
- iOS background delivery is opportunistic; force-quitting the app can prevent background relaunch.
- The native iOS target currently supports iPhone on iOS 17 or later in portrait and landscape.
- Physical-device testing is required for real BLE, camera writes, and background-location behavior; real camera GPS writes require explicit authorization.
