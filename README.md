# Camera GPS Link

Camera GPS Link is a SwiftUI iPhone app that sends the phone's current location to a supported camera over Bluetooth so newly captured photos can use the camera's latest cached GPS fix.

The first public iOS App Store release is scoped only to Sony Alpha 7C II (`ILCE-7CM2`).
The historical baseline uses firmware `2.01`, advertisement protocol `101`, the modern Sony location profile, and a strict 95-byte `DD11` packet.
See the accepted [`A7C II-only release plan`](docs/plans/2026-08-31_ios-a7c2-only-app-store-release-plan.md) and [`compatibility matrix`](docs/sony-camera-compatibility.md) for current evidence and release gates.

## What this repository contains

- **Camera GPS Link iOS app** in `CameraGPSLink/`, built with SwiftUI, CoreBluetooth, and CoreLocation.
- **Protocol and compatibility documentation** for the observed Sony A7C II BLE location flow.
- **Privacy and support documentation** for App Store distribution.

The Python `sonygeotag` CLI, BLE diagnostics, and EXIF verification tools are maintained separately in the [SonyGeoTag repository](https://github.com/narumiruna/sony-geotag).

## Requirements

- Full Xcode installation.
- iPhone running iOS 17 or later.
- Sony Alpha 7C II in the appropriate Bluetooth location-link state.
- Explicit authorization before any physical camera write test.

## Geotagging workflow

First use: tap **Add Camera** → **Search for Cameras**, select your camera, and follow the iPhone/camera pairing prompts. Tap **Pair with This Camera** only while the camera is on its pairing screen. This flow does not require Location permission. See [first-time pairing](docs/ios-app.md#add-a-camera-for-the-first-time) for Bluetooth recovery and build-policy restrictions.

1. Turn on the camera and make its Bluetooth location link available.
2. Open Camera GPS Link and tap **Start Geotagging**.
3. Grant the requested Location and Bluetooth permissions.
4. Wait for identity, capability, and `DD21` validation.
5. Wait for **Ready to Geotag** before taking photos that require location data.
6. Optionally enable **Health Alerts** in **Link Settings** to receive local warnings about interrupted or outdated camera location updates.
7. Tap **Stop Geotagging** when the shooting session ends so the app can clean up the camera controls it acquired.

**Ready to Geotag** appears only after the camera receives the first successful location packet in the current session and the phone has a writable fix. **Using Last Sent Location** distinguishes a recent camera update from a stale or unavailable phone fix; it does not guarantee GPS in any particular photo.
Public Release offers optional **Continue in Background** for its exact supported A7C II identity by explicit product decision. It requires Always Location permission, remains subject to iOS scheduling, and is not yet physically qualified; it cannot guarantee a fresh fix immediately before every photo. In **While App Is Open** mode, leaving the app stops the session and an enabled Health Alert can post a local reminder. Notifications report loss of coverage; they do not keep Bluetooth or Location running.

See the [`iOS app guide`](docs/ios-app.md) for the complete workflow, settings, permission states, diagnostics behavior, and platform limitations.

## Development

Open the Xcode project:

```bash
just ios-open
```

Run focused checks:

```bash
just source-line-check
just ios-smoke
just ios-typecheck
just ios-unit-test
just ios-ui-test
```

Run the complete local gate:

```bash
just check
```

### Continuous integration

`.github/workflows/ios-check.yml` runs on pull requests and pushes to `main`. Three isolated `macos-26` jobs cover the full local gate:

| Job | Local recipes |
| --- | --- |
| `iOS / checks` | `source-line-check-test`, `source-line-check`, `ios-smoke`, `ios-typecheck`, `ios-lint-project`, `ios-unit-test` |
| `iOS / builds` | `ios-build-sim`, `ios-build-device-nosign`, `ios-build-release-nosign`, `ios-build-qualification-nosign` |
| `iOS / ui` | `ios-ui-test` |

CI selects Xcode 26.6, iOS Simulator 26.5, and an iPhone 17. Logs and XCTest result bundles are retained for seven days. Jobs time out after 30 minutes; newer runs cancel obsolete ones. No signing secrets, physical camera writes, or release workflows are used.

All recipes select the same Xcode for Swift and `xcodebuild`, defaulting to `/Applications/Xcode.app/Contents/Developer`. Override `DEVELOPER_DIR` to use another compatible installation. `IOS_TEST_OS` and `IOS_TEST_RUNTIME` can pin the simulator OS and runtime identifier; defaults remain the latest installed iOS runtime. An existing dedicated simulator must match the selected OS. `just ios-test` recreates only that project simulator between unit and UI hosts.

To retain a focused test result, pass a new result-bundle path:

```bash
mkdir -p build/test-results
just ios-unit-test build/test-results/unit.xcresult
just ios-ui-test build/test-results/ui.xcresult
```

To rerun one UI suite without repeating the full host, use `just ios-ui-test "" CameraGPSLinkUITests/DiagnosticsSummaryUITests`. Omit the selector for the complete UI gate.

Do not run both test hosts concurrently against the same simulator.

## Project layout

```text
CameraGPSLink.xcodeproj/  Xcode project
CameraGPSLink/            SwiftUI app target
CameraGPSLinkUnitTests/   XCTest unit suite
CameraGPSLinkUITests/     XCUITest suite
CameraGPSLinkTests/       Standalone Swift smoke test
docs/                     App, protocol, privacy, support, and release documents
third_party/              Curated third-party reference index
scripts/                  Repository verification helpers
justfile                  Local iOS commands
```

## Privacy and support

**Link Settings → Help** opens these public documents on GitHub without applying draft settings:

- [Privacy Policy](docs/PRIVACY.md)
- [Support](docs/SUPPORT.md)

## Limitations

- The exact A7C II 2.01 identity passed Release-equivalent iOS foreground qualification; signed public Release validation remains required.
- Camera firmware other than a physically qualified version must fail closed in the public Release build.
- Public Release background configuration is available by explicit product decision but remains physically unverified. Background execution is opportunistic and can be prevented by force-quitting the app.
- Real BLE behavior, camera writes, background restoration, and battery use require physical-device testing.
- Camera GPS Link updates the camera's cached location for new photos and does not modify existing images.
- Health Alerts are opt-in local notifications. iOS can delay or suppress their delivery, so they do not guarantee geotagging coverage.
