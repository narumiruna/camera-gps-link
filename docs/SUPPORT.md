# Camera GPS Link Support

Camera GPS Link sends an iPhone's current location to a compatible camera over Bluetooth.
The public iOS release target is exclusively the Sony Alpha 7C II (`ILCE-7CM2`).
Initial qualification is limited to firmware `2.01`, and the iOS support claim remains pre-release until its physical write and fresh-photo GPS EXIF verification pass.
Other camera models are not supported by the public iOS release.

## Before Requesting Support

- Confirm that the iPhone runs iOS 17 or later.
- Enable Bluetooth and grant the requested location permission.
- Make the camera's Bluetooth location link available for pairing.
- In foreground-only mode, keep the app open throughout shooting. Locking the iPhone or switching apps stops location updates, regardless of the Health Alerts preference.
- Wait for **Ready to Geotag** before relying on the camera's cached location.
- If Health Alerts are enabled but unavailable, open **Link Settings** and check **Notification Permission**. Use **Retry Notification Permission** when permission remains not requested, or **Open iOS Settings** when permission is blocked.
- **Using Last Sent Location** means the camera's last confirmed update is recent, but the iPhone cannot yet send a current fix. Check its age before relying on it; **Stop Geotagging** remains available.
- Treat **iPhone Location Is Stale**, **Low Location Accuracy**, and **Location Update Delayed** as separate conditions; the Readiness rows identify whether the phone fix or camera cache needs attention.
- After a terminal connection failure, location updates stop. Fix the displayed problem and tap **Retry**; a Background preference does not automatically restart a failed foreground attempt.

Background operation is disabled in the first public Release until physical qualification passes. An enabled Health Alert can report that a foreground-only session stopped after the app entered the background, but the notification does not keep the session running. Development and qualification background behavior depends on iOS permissions and system scheduling and cannot guarantee an update immediately before every photo.

## Contact

Search existing reports or [open a support issue](https://github.com/narumiruna/camera-gps-link/issues).
Repository access is currently required; public support and privacy-document hosting remains a pre-release requirement.

Prefer **Diagnostics → Copy Diagnostic Summary**. Its preview includes app/iOS versions, distribution mode, recognized camera identity, connection state, and last-update age, but no coordinates, device identifiers, camera nicknames, raw BLE payloads, or logs. Unknown identity fields are intentionally omitted as **Unknown**. Copying does not upload the report; paste it into a support request only when you choose. The summary's local-only clipboard entry expires after five minutes.

If more detail is requested, **Copy Diagnostic Log** remains available separately. The app's diagnostic log can help investigate connection problems, but it may contain recent coordinates.
Review and redact sensitive information before posting or sharing a diagnostic log. Health notification text is local and generic, but iOS may delay or suppress delivery.
