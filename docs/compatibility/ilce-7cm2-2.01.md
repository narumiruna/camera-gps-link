# ILCE-7CM2 2.01 Sony location evidence

- Model: `ILCE-7CM2`
- Firmware: `2.01`
- Advertisement protocol version: `101` (`0x65`)
- Resolved profile: `modern`
- Confidence before test: `experimental`
- Background status: `unverified`

## Sanitized snapshot

Captured read-only on 2026-08-09 after fresh host/camera pairing. It matches the historical A7C II modern profile: service-owned DD11 write-with-response, readable DD21, writable DD30/DD31, seven-byte DD21 value, and 95-byte timezone mode.

```json
{
  "schema_version": 1,
  "captured_at": "2026-08-09T13:55:40.882+00:00",
  "identity": {
    "model": "ILCE-7CM2",
    "normalized_model": "ILCE-7CM2",
    "firmware": "2.01",
    "protocol_version": 101
  },
  "profile": {
    "kind": "modern",
    "reason": "Protocol >= 65 and complete modern location shape.",
    "protocol_version": 101,
    "experimental": false,
    "has_status_notifications": true,
    "has_time_correction": true,
    "has_area_adjustment": true
  },
  "confidence": "experimental",
  "evidence": null,
  "descriptors": [
    {
      "service_uuid": "8000cc00-cc00-ffff-ffff-ffffffffffff",
      "characteristic_uuid": "0000cc0a-0000-1000-8000-00805f9b34fb",
      "properties": ["read"]
    },
    {
      "service_uuid": "8000cc00-cc00-ffff-ffff-ffffffffffff",
      "characteristic_uuid": "0000cc0b-0000-1000-8000-00805f9b34fb",
      "properties": ["read"]
    },
    {
      "service_uuid": "8000dd00-dd00-ffff-ffff-ffffffffffff",
      "characteristic_uuid": "0000dd01-0000-1000-8000-00805f9b34fb",
      "properties": ["notify"]
    },
    {
      "service_uuid": "8000dd00-dd00-ffff-ffff-ffffffffffff",
      "characteristic_uuid": "0000dd11-0000-1000-8000-00805f9b34fb",
      "properties": ["write"]
    },
    {
      "service_uuid": "8000dd00-dd00-ffff-ffff-ffffffffffff",
      "characteristic_uuid": "0000dd21-0000-1000-8000-00805f9b34fb",
      "properties": ["read"]
    },
    {
      "service_uuid": "8000dd00-dd00-ffff-ffff-ffffffffffff",
      "characteristic_uuid": "0000dd30-0000-1000-8000-00805f9b34fb",
      "properties": ["read", "write"]
    },
    {
      "service_uuid": "8000dd00-dd00-ffff-ffff-ffffffffffff",
      "characteristic_uuid": "0000dd31-0000-1000-8000-00805f9b34fb",
      "properties": ["read", "write"]
    },
    {
      "service_uuid": "8000dd00-dd00-ffff-ffff-ffffffffffff",
      "characteristic_uuid": "0000dd32-0000-1000-8000-00805f9b34fb",
      "properties": ["read", "write"]
    },
    {
      "service_uuid": "8000dd00-dd00-ffff-ffff-ffffffffffff",
      "characteristic_uuid": "0000dd33-0000-1000-8000-00805f9b34fb",
      "properties": ["read", "write"]
    }
  ],
  "dd21": {
    "value_hex": "06 10 00 9c 02 00 00",
    "mode": {
      "include_timezone": true,
      "packet_size": 95,
      "value_hex": "06 10 00 9c 02 00 00"
    },
    "error": null
  }
}
```

## Pairing preparation

- Explicit EE01 authorization: `2026-08-09`
- Final successful action time: `2026-08-09T15:11:28Z`
- Sanitized operation: `write_ee01_pairing_init`
- Payload length: `7`
- Result: `pass` after clearing stale camera/host pairing records, completing the OS bond, and running EE01 in a separate connection while the camera remained on its pairing screen

## Python foreground result

- Platform/tool version: `macOS 26.5.2`, Python `3.14.2`, current worktree based on `feb8b33`
- Explicit write authorization: `2026-08-09`, bounded Python GPS writes to `ILCE-7CM2`
- Approved coordinate: `25.033964, 121.564468`
- Active location window: `2026-08-09T15:18:45.351Z` through `2026-08-09T15:19:45Z`
- DD11 success/not-before time: `2026-08-09T15:18:45.351Z`
- Packet size: `95`
- Packets accepted: `3`
- Sanitized operation order: `start_dd01_notify → write_dd30_lock → write_dd31_enable → read_dd32_time_correction → read_dd33_area_adjustment → read_dd21_config → write_dd11_location ×3 → write_dd31_disable → write_dd30_unlock → stop_dd01_notify`
- New image format/capture time: `HEIF` / `2026-08-09T23:19:05+08:00`
- Camera overlay: `25°02′02″, 121°33′52″`
- Cleanup diagnostic: `none`
- Result: `pass`

```json
{
  "capture_time": "2026-08-09T23:19:05+08:00",
  "capture_time_source": "EXIF original time + offset",
  "coordinate_tolerance_degrees": 0.0001,
  "expected_latitude": 25.033964,
  "expected_longitude": 121.564468,
  "image_format": "HEIF",
  "latitude": 25.03396388888889,
  "longitude": 121.56446777777778,
  "not_before": "2026-08-09T15:18:45.351000+00:00",
  "verified": true
}
```

The user explicitly accepted camera-native HEIF evidence instead of JPEG. A zero-length location window had accepted DD11 but cleaned up before capture and did not geotag the first test image; the public CLI now requires a positive active window and documents that evidence must be captured before cleanup.

## iOS foreground result

- Platform/app version: `iPhone 16 Pro`, development (`DEBUG`) build at `b0c8869`
- Explicit write authorization: `2026-09-06`, current iPhone coordinates approved for bounded A7C II testing
- Experimental confirmation reviewed: `yes`
- Approved coordinate: `25.0260469, 121.5313468`, reported accuracy `±5 m`
- Active location window: confirmed active by `2026-09-06T01:16:08+08:00` and stopped by `2026-09-06T01:19:30+08:00`
- DD11 success/not-before bound: `2026-09-06T01:16:08+08:00`, when the app already reported **Ready to Geotag** and a current camera update
- Packet size: `95`
- Packets accepted: `11`
- Sanitized operation order: `CC0B model → CC0A firmware → DD21 preflight → DD01 notify → DD30 lock → DD31 enable → DD32 time correction → DD33 area adjustment → DD11 location ×11 → DD31 disable → DD30 unlock → stop DD01 notify`
- New image format/capture time: `HEIF` / `2026-09-06T01:17:07+08:00`
- Cleanup diagnostic: `Cleanup complete`
- Result: `pass for the development foreground workflow`

```json
{
  "capture_time": "2026-09-06T01:17:07+08:00",
  "capture_time_source": "EXIF original time + offset",
  "coordinate_tolerance_degrees": 0.0001,
  "expected_latitude": 25.0260469,
  "expected_longitude": 121.5313468,
  "image_format": "HEIF",
  "latitude": 25.026065833333334,
  "longitude": 121.53133277777778,
  "not_before": "2026-09-06T01:16:08+08:00",
  "verified": true
}
```

The source HEIF remains outside the repository.
The development policy may now reuse this exact qualification candidate without volatile approval, while other unverified development profiles remain approval-gated.

## Qualification result

- Exact model/firmware/protocol/profile: `Python foreground verified; iOS development foreground verified; Release-equivalent qualification pending`
- Deviations or cleanup diagnostics: `no protocol, EXIF, or cleanup deviation; the iOS run used DEBUG rather than QUALIFICATION`
- Reviewer/date: `Python evidence recorded 2026-08-09; iOS development evidence recorded 2026-09-06`
