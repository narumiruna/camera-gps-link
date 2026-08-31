# Camera GPS Link for iPhone

Camera GPS Link sends the iPhone’s current location to a supported camera over Bluetooth so newly captured photos can use the camera’s latest cached GPS fix.

Historical verified baseline: Sony A7C II / `ILCE-7CM2` firmware `2.01`, protocol `101`, modern 95-byte profile.
The first public iOS App Store release will support only this camera and will not expose experimental writes for other models.
See the accepted [`A7C II-only iOS App Store release plan`](plans/2026-08-31_ios-a7c2-only-app-store-release-plan.md) and the current [`compatibility matrix`](sony-camera-compatibility.md).

## Geotagging workflow

The home screen is organized around shooting readiness rather than BLE protocol details:

1. Turn on the camera and make its Bluetooth location link available.
2. Tap **Start Geotagging**.
3. Grant location access when iOS asks. Camera GPS Link does not start the camera write flow before usable permission is available.
4. Follow the visible stages: looking for the camera, connecting, identity/profile discovery, preparing location, and sending the first location.
5. If the exact model/firmware/protocol/profile is unverified, review **Experimental Camera Profile** and choose Continue or Cancel. Cancel performs no subscription or application write.
6. Wait for **Ready to Geotag** before taking photos that need location data.

**Ready to Geotag** appears only after the camera has successfully received at least one location packet in the current session. The Readiness group separately reports the camera, iPhone location, and last successful camera update.

During a foreground connection attempt, **Cancel** remains available. Camera search, connection, and setup use bounded waits; a timeout preserves the remembered camera and offers **Retry** instead of leaving the interface indefinitely busy.

While ready:

- **Send Current Location** requests an immediate refresh.
- **Stop Geotagging** safely closes the location link. It is reversible and does not delete settings or camera identity.

## Link Settings

Open **Link Settings** from the home screen. Changes are staged until **Apply**; **Cancel**, keyboard cancellation, or interactive sheet dismissal leaves persisted settings and running services unchanged.

### Connection Availability

- **While App Is Open** — runs only while Camera GPS Link is open.
- **Continue in Background** — keeps location and remembered-camera reconnect behavior active when iOS permits it. This requires Always Location permission for reliable background updates.

### Location Updates

- **Battery Saver** — targets approximately 100 m location accuracy and sends about every 120 seconds.
- **Best Accuracy** — uses the best available GPS accuracy and sends about every 30 seconds, using more battery.

The Effect Preview describes the concrete permission, accuracy, frequency, and battery consequences before Apply. Both choices are applied together. If application fails, the previous valid settings remain active.

Within the current app identity, updates keep the same stored behavior: Background defaults off, Battery Saver defaults on, and the remembered CoreBluetooth peripheral remains unchanged. The bundle identifier changed from an earlier development identity to `dev.narumi.cameragpslink`; iOS treats those as separate apps, so sandboxed settings from an older development install do not migrate automatically.

## Permission and partial states

Location permission is requested after the user taps Start. If access is denied or restricted, Camera GPS Link remains disconnected and offers **Review Location Permission**.

When Continue in Background is selected but only When-In-Use permission is available:

- foreground geotagging continues to work;
- the home screen shows **Background Permission Needed**;
- **Allow Background Location** provides the recovery action;
- the app does not claim that background setup is complete.

Background reconnect is shown as **Waiting for Camera**, not as an endless foreground progress state. iOS can still throttle background scans, timers, location updates, and `BGAppRefreshTask` delivery. Force-quitting the app can prevent background relaunch.

## Diagnostics and privacy

**Diagnostics** is one level below the home screen and preserves the technical information needed for troubleshooting:

- sanitized detected model, firmware, protocol, modern/legacy profile, and confidence;
- packets sent, strict DD11/DD21 packet mode, operation order, cleanup status, update interval, and pending reconnect;
- pairing state and last-send time, without exposing the private remembered peripheral identifier;
- location permission, mode, coordinate, accuracy, and fix time;
- a bounded 120-line debug log.

Diagnostic logs can include recent coordinates. Review the warning and log contents before using **Copy Diagnostic Log** or sharing the result.

## Sony protocol behavior

The app resolves behavior from complete Sony CC/DD/EE service discovery and required characteristic properties:

- **Modern:** protocol `>=65`, DD11/DD21, and write-with-response DD30/DD31. After approval it optionally subscribes DD01, writes DD30 then DD31, optionally reads DD32/DD33, strictly validates DD21, then sends DD11.
- **Legacy:** known protocol `<65`, DD11/DD21, and both DD30/DD31 absent. It validates DD21 and sends DD11 without controls or notifications.
- **Unsupported:** missing/wrong properties, partial controls, inconsistent protocol shape, unknown-version legacy shape, or a blocked registry identity. It performs no subscription or application write.

Strict DD21 accepts only evidence-backed 6/7-byte framing and controls the 95- or 91-byte DD11 packet. Failure, cancellation, and timeout compensate every dispatched, possibly applied modern control in DD31-then-DD30 order. Cleanup cannot be disabled.

Ordinary and experimental location sessions never send EE01. Diagnostics exposes **Initialize Camera Pairing** as a separate confirmed action after the active location session is stopped; it performs fresh identity/profile discovery and requires experimental approval when applicable before showing the final EE01 confirmation. The camera must be explicitly on its pairing screen.

## Build and test

Open the shared project:

```bash
just ios-open
```

Run focused checks:

```bash
just ios-smoke
just ios-typecheck
just ios-unit-test
just ios-ui-test
just ios-test
```

Run the complete iOS gate:

```bash
just ios-check
```

The XCTest suite covers strict capability/DD21 truth tables, modern/legacy plans and compensation order, exact identity confidence, settings compatibility and rollback, permission sequencing, foreground timeout policy, experimental/unsupported UI, cancellation, retries, loading/partial/error states, settings preview/apply/cancel/dismissal, sanitized diagnostics and pairing confirmation, Dynamic Type, appearances, reduced motion, accessibility audits, and portrait/landscape layouts. Debug-only launch fixtures make simulator UI tests deterministic and are unavailable in Release builds.

A physical iPhone is still required to validate real CoreBluetooth behavior, background restoration, and camera writes. Do not perform a real camera GPS write without explicit authorization.

## Platform and accessibility

- Bundle identifier: `dev.narumi.cameragpslink`.
- Deployment target: iOS 17 or later.
- Supported native device family: iPhone.
- Supported orientations: portrait and landscape.
- Layouts reflow for accessibility text sizes instead of truncating critical status or actions.
- Status uses text and symbols rather than color alone.
- Controls use accessible target sizes, semantic contrast, VoiceOver labels and restrained state announcements, keyboard default/cancel actions, and reduced-motion-safe feedback.

## Known limitations

- The exact A7C II baseline is historical evidence only; runtime confidence remains experimental until the external Python evidence is current and a separately authorized post-refactor iOS EXIF regression passes.
- A7 III, A7 IV, A6700, A7R V, A7S III, A1, ZV-E1, and ZV-E10 II remain unverified until their exact rows have independent evidence.
- Background execution is opportunistic and cannot guarantee a fresh location immediately before every shutter release.
- The app updates the camera’s cached location for new photos; it does not modify existing images.
- Real BLE and background wake behavior cannot be fully simulated by XCUITest.
