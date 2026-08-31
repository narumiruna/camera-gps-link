# Camera GPS Link Support

Camera GPS Link sends an iPhone's current location to a compatible camera over Bluetooth.
The public iOS release target is exclusively the Sony Alpha 7C II (`ILCE-7CM2`).
Initial qualification is limited to firmware `2.01`, and the iOS support claim remains pre-release until its physical write and fresh-photo GPS EXIF verification pass.
Other camera models are not supported by the public iOS release.

## Before Requesting Support

- Confirm that the iPhone runs iOS 17 or later.
- Enable Bluetooth and grant the requested location permission.
- Make the camera's Bluetooth location link available for pairing.
- Keep the app open while establishing the first connection.
- Wait for **Ready to Geotag** before relying on the camera's cached location.

Background operation depends on iOS permissions and system scheduling and cannot guarantee an update immediately before every photo.

## Contact

Search existing reports or [open a support issue](https://github.com/narumiruna/sony-geotag/issues).
Include the iPhone model, iOS version, camera model, and the visible app status.

The app's diagnostic log can help investigate connection problems, but it may contain recent coordinates.
Review and redact sensitive information before posting or sharing a diagnostic log.
