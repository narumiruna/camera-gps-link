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

1. Turn on the camera and make its Bluetooth location link available.
2. Open Camera GPS Link and tap **Start Geotagging**.
3. Grant the requested Location and Bluetooth permissions.
4. Wait for identity, capability, and `DD21` validation.
5. Wait for **Ready to Geotag** before taking photos that require location data.
6. Tap **Stop Geotagging** when the shooting session ends so the app can clean up the camera controls it acquired.

**Ready to Geotag** appears only after the camera receives the first successful location packet in the current session.
The public Release build remains foreground-only until background qualification passes. Development and qualification background updates remain subject to iOS permissions and scheduling and cannot guarantee a fresh fix immediately before every photo.

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

- [Privacy Policy](docs/PRIVACY.md)
- [Support](docs/SUPPORT.md)

## Limitations

- The A7C II iOS write and fresh-photo GPS EXIF regression remains required before the exact identity can be promoted to verified.
- Camera firmware other than a physically qualified version must fail closed in the public Release build.
- Public Release background operation is disabled until physical qualification passes; development and qualification background execution remains opportunistic and can be prevented by force-quitting the app.
- Real BLE behavior, camera writes, background restoration, and battery use require physical-device testing.
- Camera GPS Link updates the camera's cached location for new photos and does not modify existing images.
