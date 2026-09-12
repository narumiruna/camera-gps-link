# Camera GPS Link for iPhone

Camera GPS Link sends the iPhone’s current location to a supported camera over Bluetooth so newly captured photos can use the camera’s latest cached GPS fix.

Historical verified baseline: Sony A7C II / `ILCE-7CM2` firmware `2.01`, protocol `101`, modern 95-byte profile.
The first public iOS App Store release will support only this camera and will not expose experimental writes for other models.
See the accepted [`A7C II-only iOS App Store release plan`](plans/2026-08-31_ios-a7c2-only-app-store-release-plan.md) and the current [`compatibility matrix`](sony-camera-compatibility.md).

## Add a camera for the first time

Pairing does not require Location permission or a remembered camera. Existing distribution-policy restrictions still apply: public Release cannot write to identities absent from its verified allowlist, which currently remains empty.

1. Stop any active geotagging session and tap **Add Camera** on the home screen.
2. Enable Bluetooth on the camera and open **Bluetooth → Pairing** or **Smartphone Connection**, depending on the model.
3. Tap **Search for Cameras**. Allow Bluetooth access when iOS asks. If Bluetooth is off, turn it on in iPhone Settings; the app cannot enable it itself. A pending foreground search resumes when Bluetooth becomes ready, unless cancelled or timed out.
4. Select the intended camera from the list. Search uses Sony manufacturer data and connectable advertisements, not just a matching name. It does not automatically connect to the first result or a remembered device.
5. Accept any system and camera pairing prompts during identity reads. Development builds may request experimental-profile approval; qualification and public Release retain exact identity/descriptor checks.
6. Confirm that the camera remains on its pairing screen, then tap **Pair with This Camera**. This sends EE01 once with response, without starting location sharing.
7. After **Pairing Initialization Accepted**, tap **Done**, enable **Location Info. Link** on the camera, return to shooting mode, and start geotagging.

The completion message means the camera acknowledged the pairing initialization write, not that the app independently inspected the iOS bond. A subsequent location session verifies the usable location link.

Search lasts 15 seconds and retains any results for selection. Waiting for Bluetooth is bounded to 60 seconds; pairing connection/discovery stages to 120 seconds; individual identity reads and the pairing write to 60 seconds. Cancel or sheet dismissal stops pairing; entering the background also cancels it even when background geotagging is configured. A system permission prompt only makes the app inactive, so it does not cancel pairing. Returning from iPhone Settings after background cancellation requires a new search.

If permission is denied, use **Open iPhone Settings**. If pairing records are inconsistent, forget the camera in iPhone Bluetooth settings and remove the iPhone in the camera's **Manage Paired Device** menu, then repeat the procedure. These actions remain user-controlled; the app cannot delete an iOS bond.

## Geotagging workflow

The home screen is organized around shooting readiness rather than BLE protocol details:

1. Turn on the camera and make its Bluetooth location link available.
2. Tap **Start Geotagging**.
3. Grant location access when iOS asks. Camera GPS Link does not start the camera write flow before usable permission is available.
4. Follow the visible stages: looking for the camera, connecting, identity/profile discovery, preparing location, and sending the first location.
5. Development builds may show **Experimental Camera Profile** only after read-only identity, descriptor, and strict DD21 preflight; Cancel performs no subscription or application write. The exact A7C II qualification candidate may proceed without this volatile approval after recorded development evidence, while qualification and public Release builds never offer the override.
6. Wait for **Ready to Geotag** before taking photos that need location data.

**Ready to Geotag** appears only after the camera has successfully received at least one location packet in the current session, its last update is no more than five minutes old, and the phone has a writable fix. The Readiness group separately reports the camera, iPhone location, and last successful camera update. This status does not verify GPS EXIF in individual photos.

During a foreground connection attempt, **Cancel** remains available. Camera search, connection, and setup use bounded waits; a timeout preserves the remembered camera and offers **Retry** instead of leaving the interface indefinitely busy. Terminal failures and unsupported identities stop iPhone location updates without bypassing camera-control cleanup. Enabling Background does not turn a failed foreground attempt into automatic retry; start again explicitly. Eligible background reconnection retains location updates when permissions and iOS allow them.

While ready:

- **Send Current Location** requests an immediate refresh when the iPhone has a writable fix.
- **Stop Geotagging** safely closes the location link. It is reversible and does not delete settings or camera identity.

The Readiness rows distinguish the camera's last confirmed update from the current iPhone fix. A camera update becomes delayed after five minutes. An iPhone fix is shown as stale after 120 seconds, invalid when its accuracy or timestamp cannot be used, and low accuracy above 100 m. Low accuracy is advisory and does not block a valid camera write.

**Using Last Sent Location** replaces the green Ready presentation when the camera update is still recent but the phone fix is stale, missing, invalid, or future-dated. It shows when the location was sent and keeps **Stop Geotagging** available, without offering a manual send of an unusable fix. After the camera update exceeds five minutes, **Location Update Delayed** takes precedence.

In foreground-only mode, the home screen always explains: **Keep this app open. Locking the iPhone or switching apps stops location updates.** This explanation does not depend on enabling Health Alerts.

## Link Settings

Open **Link Settings** from the home screen. Changes are staged until **Apply**; **Cancel**, keyboard cancellation, or interactive sheet dismissal leaves persisted settings and running services unchanged.

The **Help** section links to the public [Privacy Policy](https://github.com/narumiruna/camera-gps-link/blob/main/docs/PRIVACY.md) and [Support](https://github.com/narumiruna/camera-gps-link/blob/main/docs/SUPPORT.md) documents on GitHub. Following a link does not apply draft settings or request permissions. Switching to GitHub or a browser still follows the foreground-only session limitation above.

### Connection Availability

- **While App Is Open** — runs only while Camera GPS Link is open.
- **Continue in Background** — available in development, qualification, and public Release builds. It keeps location and remembered-camera reconnect behavior active when iOS permits it and requires Always Location permission.

Public Release exposes Background by explicit product decision for its exact supported A7C II identity, although physical background qualification remains pending. **While App Is Open** remains the default. Temporary inactive states such as system interruptions do not stop the link; actual background entry stops only a foreground-only session.

### Location Updates

- **Battery Saver** — targets approximately 100 m location accuracy and sends about every 120 seconds.
- **Best Accuracy** — uses the best available GPS accuracy and sends about every 30 seconds, using more battery.

### Health Alerts

**Health Alerts** are off by default. Enabling them through Apply requests iOS notification permission in context; merely launching the app or opening Link Settings does not prompt. If a transient failure leaves permission at **Not Requested**, Link Settings offers **Retry Notification Permission**. If permission is blocked, the preference remains on so Link Settings can explain the mismatch and offer **Open iOS Settings**.

Health Alerts use local notifications with generic text and warn about three conditions:

- a previously ready camera link remains interrupted for more than 10 seconds;
- the camera's last confirmed location reaches five minutes old;
- a ready foreground-only session stops because the app entered the background.

A reconnect cancels any pending interruption alert and schedules the next stale-update deadline. The app does not post a separate recovery alert because iOS does not provide a race-free delivery confirmation for the earlier warning. Stop, Cancel, initial connection failure, unsupported profiles, and pairing do not send health alerts. Notification delivery is controlled by iOS and does not keep Bluetooth, Location, or the app running.

The Effect Preview describes the concrete permission, accuracy, frequency, battery, and alert consequences before Apply. All choices are applied together. If application fails, the previous valid settings remain active.

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

- detected model, firmware, protocol, modern/legacy profile, and confidence;
- packets sent, strict DD11/DD21 packet mode, operation order, cleanup status, update interval, and pending reconnect;
- Health Alerts preference, notification permission, health classification, and managed alert deadline;
- pairing state and last-send time, without exposing the private remembered peripheral identifier;
- location permission, mode, coordinate, accuracy, and fix time;
- a bounded 120-line debug log.

**Copy Diagnostic Summary** works even when the log is empty. **Summary Preview** shows the exact allowlisted text: app version/build, iOS version, distribution mode, a recognized exact camera identity, connection state, and age of the last confirmed update. Unknown or unrecognized identity fields display **Unknown**. The summary excludes coordinates, camera nicknames, device identifiers, raw BLE payloads, free-form errors, and log messages. Copying does not request permissions, start geotagging, or upload data. Its clipboard entry is local to the iPhone and expires after five minutes.

**Copy Diagnostic Log** remains separate. Diagnostic logs and on-screen location details can include recent coordinates; review the warning and log contents before copying or sharing them. The entire Diagnostics screen is not de-identified. Local health notification text never includes coordinates, peripheral identifiers, raw camera identity, firmware, or BLE payloads.

## Sony protocol behavior

The app resolves behavior from complete Sony CC/DD/EE service discovery and required characteristic properties:

- **Modern:** protocol `>=65`, DD11/DD21, and write-with-response DD30/DD31. Location-session read-only preflight strictly validates DD21 before any approval, notification subscription, or write. An authorized session then optionally subscribes DD01, writes DD30 then DD31, optionally reads DD32/DD33, and sends DD11.
- **Legacy:** known protocol `<65`, DD11/DD21, and both DD30/DD31 absent. Read-only preflight validates DD21 before an authorized session sends DD11 without controls or notifications.
- **Unsupported:** missing/wrong properties, partial controls, inconsistent protocol shape, unknown-version legacy shape, a blocked registry identity, or a distribution-policy mismatch. It performs no subscription or application write. During automatic location search, exact-target builds skip a non-target Sony candidate and continue the bounded scan for another camera. Explicit pairing rejects an unsupported selection instead of silently switching to another camera.

Strict DD21 accepts only evidence-backed 6/7-byte framing and controls the 95- or 91-byte DD11 packet. Qualification and public Release entries may require one exact packet size. Failure, cancellation, and timeout compensate every dispatched, possibly applied modern control in DD31-then-DD30 order. Cleanup cannot be disabled.

Ordinary and experimental location sessions never send EE01. **Add Camera** and Diagnostics → **Search and Pair Camera** open the same separate pairing flow. It performs fresh identity/profile/descriptor discovery and distribution-policy checks before final EE01 confirmation. Pairing does not read DD21 or negotiate a location packet size: those location-only checks run in the later location session, avoiding a location-preflight dependency before Sony pairing initialization. Identity reads can trigger iOS bonding prompts. Only development builds may require and accept experimental pairing approval. The camera must be explicitly on its pairing screen.

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
just ios-build-release-nosign
just ios-build-qualification-nosign
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

- The exact A7C II 2.01 identity has Python, iOS development, and Release-equivalent iOS qualification foreground EXIF evidence; signed public Release validation remains pending.
- A7 III, A7 IV, A6700, A7R V, A7S III, A1, ZV-E1, and ZV-E10 II remain unverified until their exact rows have independent evidence.
- Public Release offers Background by explicit product decision before physical background qualification. Background execution remains opportunistic and cannot guarantee a fresh location immediately before every shutter release.
- The app updates the camera’s cached location for new photos; it does not modify existing images.
- Real BLE, notification delivery, and background wake behavior cannot be fully simulated by XCUITest.
- Local Health Alerts can be delayed or suppressed by iOS and never guarantee geotagging coverage.
