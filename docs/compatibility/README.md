# Compatibility evidence format

Create one file per exact model/firmware qualification, named `<normalized-model>-<firmware>.md`. Do not commit the JPEG/HEIF evidence image, raw BLE log, peripheral identifier, Bluetooth address, credentials, manufacturer tail, DD11 bytes/coordinates beyond the approved test coordinate, or unknown payloads.

Copy this template:

~~~markdown
# <model> <firmware> Sony location evidence

- Model: `<normalized model>`
- Firmware: `<exact firmware>`
- Advertisement protocol version: `<decimal and hex>`
- Resolved profile: `<modern|legacy>`
- Confidence before test: `experimental`
- Background status: `unverified`

## Sanitized snapshot

```json
<paste sonygeotag compatibility-snapshot output>
```

## Python foreground result

- Platform/tool version: `<OS, Python package commit>`
- Explicit write authorization: `<date/reference; no private identity>`
- Approved coordinate: `<latitude>, <longitude>`
- DD11 success/not-before time: `<ISO-8601 with offset>`
- Packet size: `<91|95>`
- Sanitized operation order: `<operation names only>`
- New image format/capture time: `<JPEG|HEIF>` / `<unambiguous ISO-8601 with offset>`
- EXIF verifier output: `<numeric sanitized JSON>`
- Result: `<pass|fail>`

## iOS foreground result

- Platform/app version: `<iOS/device class, app commit>`
- Explicit write authorization: `<date/reference; no private identity>`
- Approved coordinate: `<latitude>, <longitude>`
- Experimental confirmation reviewed: `<yes|not required>`
- DD11 success/not-before time: `<ISO-8601 with offset>`
- Packet size: `<91|95>`
- Sanitized operation order: `<operation names only>`
- New image format/capture time: `<JPEG|HEIF>` / `<unambiguous ISO-8601 with offset>`
- EXIF verifier output: `<numeric sanitized JSON>`
- Result: `<pass|fail>`

## Qualification result

- Exact model/firmware/protocol/profile: `<verified|unverified|unsupported>`
- Deviations or cleanup diagnostics: `<none or sanitized text>`
- Reviewer/date: `<review record>`
~~~

A passing coordinate must be within `0.0001°`; image time must be strictly later than the recorded DD11 success/not-before time. Prefer DateTimeOriginal with its EXIF offset, fall back to GPS UTC when needed, or pass an explicit IANA camera timezone to `sonygeotag verify-exif`.
