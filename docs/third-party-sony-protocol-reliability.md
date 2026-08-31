# Third-party Sony BLE protocol reliability

## Conclusion

For the Sony A7C II (`ILCE-7CM2`) BLE location/geotag protocol, **`third_party/CameraSync/` is the preferred third-party reference overall and in every location-specific protocol area**.

Use CameraSync's production Sony sources as the primary reference, especially `SonyGattSpec.kt`, `SonyProtocol.kt`, and `SonyConnectionDelegate.kt`; do not treat every CameraSync document as authoritative because several documentation errors and one source/document lifecycle difference are identified below.

`third_party/ILCE7M3ExternalGps/PROTOCOL_EN.md` is a useful secondary, older-model packet-format reference because the local validated encoder reproduces its 95-byte example byte for byte, but **its ESP32 source must not be copied for A7C II**: it omits the modern DD30/DD31 flow and writes only 93 or 89 bytes while its own protocol document requires 95 or 91 bytes.

No other checked-in library implements Sony's DD location service. `alpharemote` is useful for A7C II **FF00 Bluetooth-remote** evidence, and `freemote` is useful for older-model advertisement/FF00 evidence, but neither is a geotag protocol reference.

Neither direct candidate documents a physical A7C II geotag/EXIF test. The local A7C II observation remains the highest-quality evidence: two 95-byte DD11 writes were accepted and a new photo contained the transmitted coordinate ([`docs/a7c2-ble-map.md:145-152`](a7c2-ble-map.md#L145-L152)).

## Method and decision rules

The comparison uses the user's confirmation that the current implementation is correct on a physical A7C II, while distinguishing the stronger live observations from behavior that is only encoded in local source/tests.

Comparison labels mean:

- **Exact match**: same value, bytes, or operation order as the A7C II baseline.
- **Compatible, not A7C II-verified**: does not conflict, but was not proved by the recorded A7C II run.
- **Contradiction**: differs from the validated baseline or from the library's own protocol document.
- **Not covered**: the library provides no evidence for the claim.

A critical contradiction in packet length/bytes, characteristic direction, or the required modern setup sequence prevents a library from being recommended as executable A7C II source, regardless of how much adjacent Sony material it contains.

## A7C II ground-truth matrix

| Atomic behavior | A7C II baseline | Evidence level |
| --- | --- | --- |
| Advertisement identity | Sony company ID `0x012D`; payload begins with little-endian camera device type `03 00`; payload byte 2 is protocol version; observed A7C II version is `0x65`/101 ([`docs/a7c2-ble-map.md:7-10`](a7c2-ble-map.md#L7-L10), [`docs/a7c2-ble-map.md:111-113`](a7c2-ble-map.md#L111-L113), [`sony_protocol.py:9-11,54-83`](https://github.com/narumiruna/sony-geotag/blob/main/src/sonygeotag/sony_protocol.py#L9-L11)). | Live observation plus local parser |
| Unlock threshold | Protocol version `>= 65` requires the modern unlock flow ([`sony_protocol.py:74-83`](https://github.com/narumiruna/sony-geotag/blob/main/src/sonygeotag/sony_protocol.py#L74-L83), [`docs/a7c2-ble-map.md:112-115`](a7c2-ble-map.md#L112-L115)). | A7C II version and successful modern flow |
| Location and pairing UUIDs | Service `8000DD00`; DD01 notify, DD11 write, DD21 read, DD30/DD31 control, DD32/DD33 read; pairing service `8000EE00` and EE01 write ([`sony_protocol.py:16-33`](https://github.com/narumiruna/sony-geotag/blob/main/src/sonygeotag/sony_protocol.py#L16-L33)). | GATT observation plus local source |
| Pairing initialization | EE01 accepts `06 08 01 00 00 00 00` while the camera is in the required pairing state ([`docs/a7c2-ble-map.md:145-147`](a7c2-ble-map.md#L145-L147), [`sony_protocol.py:32-33,91-93`](https://github.com/narumiruna/sony-geotag/blob/main/src/sonygeotag/sony_protocol.py#L32-L33)). | Live A7C II write |
| Initial session order | Subscribe DD01; optional EE01 when pairing; write DD30=`01`; write DD31=`01`; read DD32, DD33, then DD21; then send DD11 ([`sony_location.py:106-152`](https://github.com/narumiruna/sony-geotag/blob/main/src/sonygeotag/sony_location.py#L106-L152), [`CameraBLEManager.swift:338-362`](../CameraGPSLink/CameraBLEManager.swift#L338-L362)). | Successful A7C II flow and both implementations |
| DD21 capability | `(data[4] & 0x02) != 0` selects the 95-byte timezone form; otherwise use 91 bytes ([`sony_protocol.py:35-36,86-89`](https://github.com/narumiruna/sony-geotag/blob/main/src/sonygeotag/sony_protocol.py#L35-L36), [`docs/a7c2-ble-map.md:150-151`](a7c2-ble-map.md#L150-L151)). | Live DD21 value `06 10 00 9c 02 00 00` and accepted 95-byte writes |
| DD11 common layout | Big-endian payload length at 0; `08 02 FC` at 2-4; timezone flag at 5; `10 10 10` at 8-10; signed coordinates multiplied by `10^7` at 11 and 15; UTC timestamp at 19-25; zero-reserved tail ([`sony_protocol.py:96-127`](https://github.com/narumiruna/sony-geotag/blob/main/src/sonygeotag/sony_protocol.py#L96-L127)). | User-confirmed implementation; coordinate confirmed by EXIF |
| DD11 timezone layout | 95-byte packet has signed big-endian standard-offset minutes at 91-92 and DST-savings minutes at 93-94; the 91-byte form omits them ([`sony_protocol.py:102-131`](https://github.com/narumiruna/sony-geotag/blob/main/src/sonygeotag/sony_protocol.py#L102-L131)). | 95-byte form accepted on A7C II; field interpretation comes from implementation/references |
| Write behavior and cadence | DD11 is written with response; the validated flow sends repeatedly, normally about every 30 seconds ([`sony_location.py:204-229,282-288`](https://github.com/narumiruna/sony-geotag/blob/main/src/sonygeotag/sony_location.py#L204-L229), [`docs/a7c2-ble-map.md:116-120`](a7c2-ble-map.md#L116-L120), [`CameraBLEManager.swift:391-427,476-490`](../CameraGPSLink/CameraBLEManager.swift#L391-L427)). | Successful A7C II writes; cadence is local policy |
| Cleanup order | Stop/disable transfer with DD31=`00`, then unlock with DD30=`00`; DD01 subscription is stopped where the transport supports explicit teardown ([`sony_location.py:154-173,264-279`](https://github.com/narumiruna/sony-geotag/blob/main/src/sonygeotag/sony_location.py#L154-L173), [`CameraBLEManager.swift:190-191`](../CameraGPSLink/CameraBLEManager.swift#L190-L191)). | User-confirmed implementation; explicit final values not separately recorded in live notes |

The live EXIF check proves that the selected 95-byte packet and coordinate fields work together; it does not independently prove every reserved-byte meaning, the 91-byte legacy form, MTU 158, or behavior on another Sony model.

## Complete `third_party/*/` inventory

The revisions below are the local checkout HEADs examined on 2026-08-09. A repository-wide exact search for `8000DD00` and DD01/DD11/DD21/DD30-DD33 found location identifiers only in CameraSync and ILCE7M3ExternalGps.

| Library and pinned revision | Scope/model evidence | Disposition |
| --- | --- | --- |
| `CameraSync` `5d9a2f53a422ddfa397cccc3c5d4e321142b649d` | Sony Alpha/ZV BLE documentation cites decompiled Creators' App and public reverse engineering ([`docs/sony/README.md:1-13`](../third_party/CameraSync/docs/sony/README.md#L1-L13)); the app's general compatibility list includes A7C II but does not claim an A7C II location test ([`FIRMWARE_UPDATES.md:307-322`](../third_party/CameraSync/docs/sony/FIRMWARE_UPDATES.md#L307-L322)). | **Direct; preferred** |
| `ILCE7M3ExternalGps` `f595dc5b8bfb751fde1c83b477264358047b9c57` | Reverse-engineered BLE external GPS for ILCE-7M3; the author says the 2021 code is abandoned, “seems to work,” and is reference-only ([`README_EN.md:1-5`](../third_party/ILCE7M3ExternalGps/README_EN.md#L1-L5)). | **Direct; document-only secondary** |
| `alpha-shot` `6556a30771739e5a6f0cf8b4bb41338d007d224e` | BLE photo trigger; geotagging is only a future goal ([`README.md:3-13`](../third_party/alpha-shot/README.md#L3-L13)); implemented service is FF00/FF01/FF02 ([`SonyCameraControl.kt:201-214`](../third_party/alpha-shot/composeApp/src/commonMain/kotlin/SonyCameraControl.kt#L201-L214)). | Adjacent Sony BLE remote |
| `alpharemote` `14df543de969cb8434d85fd26065be51d1683f96` | FF00 Bluetooth remote with A7C II explicitly listed among confirmed models ([`README.md:18-28`](../third_party/alpharemote/README.md#L18-L28)); it explicitly does not implement geotagging ([`README.md:51-53`](../third_party/alpharemote/README.md#L51-L53)). | Adjacent; best A7C II FF00 evidence |
| `esp32-a7iv-rc` `f79f8601d9eb8111008cdc413ac62a415a985724` | Pre-alpha A7 IV BLE remote ([`README.md:1-18`](../third_party/esp32-a7iv-rc/README.md#L1-L18)) using only FF00/FF01/FF02 ([`src/main.cpp:96-124`](../third_party/esp32-a7iv-rc/src/main.cpp#L96-L124)). | Adjacent Sony BLE remote |
| `freemote` `9c2670dbca116d9aa557e0e02526eee7e5215919` | NRF52840 FF00 remote physically tried on A7 III ([`README.md:1-13`](../third_party/freemote/README.md#L1-L13)); it documents Sony manufacturer data and location-support/status bits but implements no DD service ([`BLECamera.cpp:225-257`](../third_party/freemote/src/BLECamera.cpp#L225-L257)). | Adjacent advertisement/FF00 evidence |
| `puckjs-sony-remote` `7c1ee1d1657dbd39790a442fd5534cf53c859a2d` | Puck.js FF00 shutter remote ([`alpha-remote.js:35-39`](../third_party/puckjs-sony-remote/alpha-remote.js#L35-L39)) derived from alpharemote rather than independent location research ([`README.md:91-112`](../third_party/puckjs-sony-remote/README.md#L91-L112)). | Adjacent, derivative FF00 evidence |
| `sony_camera_ble_remote` `3bdfebaaf7b2111c603e4c1bb3f4c9f02d8288fa` | nRF Connect FF00 shutter macros; pairing/bonding was not implemented in the attempted ESP32 version ([`README.md:1-7`](../third_party/sony_camera_ble_remote/README.md#L1-L7), [`Capture.xml:2-16`](../third_party/sony_camera_ble_remote/Capture.xml#L2-L16)). | Adjacent, limited FF00 evidence |
| `Sony-PMCA-RE` `a82f5baaa8e9c3d9f28f94699e860fb2e48cc8e0` | Firmware/settings reverse engineering over USB ([`README.md:1-2`](../third_party/Sony-PMCA-RE/README.md#L1-L2)). | Out of scope |
| `SonyAlphaUSB` `6b459641a2b7fa778e2a8acfa9067c841aca5f96` | Windows USB/WIA/PTP control, tested on A7 III ([`README.md:1-13`](../third_party/SonyAlphaUSB/README.md#L1-L13)). | Out of scope |
| `alphawire` `3e7bb0a468694d7e47c9374b898d960828b36e2a` | Sony Alpha USB/PTP control, with PTP/IP as a separate backend ([`readme.md:3-16`](../third_party/alphawire/readme.md#L3-L16), [`readme.md:33-74`](../third_party/alphawire/readme.md#L33-L74)). | Out of scope |
| `darkgrade` `26e1b0765dd70c832dbf9fab0384670b462398dc` | TypeScript ISO-15740/PTP implementation using Node USB ([`README.md:7-23`](../third_party/darkgrade/README.md#L7-L23), [`README.md:147-152`](../third_party/darkgrade/README.md#L147-L152)). | Out of scope |
| `libgphoto2` `77a6c7008539ba2e0cda83c1a71014686fe4374b` | General camera library whose documented transport section is USB Mass Storage/PTP/MTP ([`README.md:19-29`](../third_party/libgphoto2/README.md#L19-L29)); its unrelated PTP opcode `0xDD11` is not a BLE characteristic. | Out of scope |
| `libptp` `b8f542703a80518d22d7f2d86c57353a4283a1a9` | PTP library; only USB transport had been tested ([`README:28-31`](../third_party/libptp/README#L28-L31), [`README:41-47`](../third_party/libptp/README#L41-L47)). | Out of scope |
| `remote-camera-control-rs` `03a2e81379a0c89393eaf45aa86971253d56a87b` | Sony ScalarWebAPI/PTP-IP control with physical A7 III and A6700 validation ([`README.md:27-45`](../third_party/remote-camera-control-rs/README.md#L27-L45), [`README.md:57-69`](../third_party/remote-camera-control-rs/README.md#L57-L69)). | Out of scope |
| `sony-alpha-python` `d40b7a080617664a4efb107930910bf63347f82e` | Network PTP3 over SSH for examples such as FX30/A6700 ([`README.md:1-18`](../third_party/sony-alpha-python/README.md#L1-L18)). | Out of scope |

## Direct-candidate comparison

| Claim | CameraSync | ILCE7M3ExternalGps |
| --- | --- | --- |
| Advertisement identity/version | **Exact match.** Source parses Sony `0x012D`, little-endian device `0x0003`, payload byte 2, and threshold 65 ([`SonyCameraVendor.kt:25-29,80-104`](../third_party/CameraSync/app/src/main/kotlin/dev/sebastiano/camerasync/vendors/sony/SonyCameraVendor.kt#L25-L29)). | **Compatible but imprecise.** The table correctly places company ID at raw 0-1 and device at 2-3, but labels raw bytes 4-5 together as the protocol version even though byte 4 is the version and byte 5 is reserved ([`PROTOCOL_EN.md:1-18`](../third_party/ILCE7M3ExternalGps/PROTOCOL_EN.md#L1-L18)). |
| DD/EE UUID map | **Exact and complete** for DD01/DD11/DD21/DD30-DD33 and EE01 ([`SonyGattSpec.kt:18-68`](../third_party/CameraSync/app/src/main/kotlin/dev/sebastiano/camerasync/vendors/sony/SonyGattSpec.kt#L18-L68)). | Protocol document covers DD01/DD11/DD21/DD30/DD31 and EE01 ([`PROTOCOL_EN.md:30-48`](../third_party/ILCE7M3ExternalGps/PROTOCOL_EN.md#L30-L48)); production source only looks up DD21/DD11 ([`CameraBle.h:36-43`](../third_party/ILCE7M3ExternalGps/src/CameraBle.h#L36-L43)). |
| EE01 payload | Production source returns the **exact seven bytes** ([`SonyProtocol.kt:174,259`](../third_party/CameraSync/app/src/main/kotlin/dev/sebastiano/camerasync/vendors/sony/SonyProtocol.kt#L174)); generic pairing code writes them with response ([`KableCameraRepository.kt:363-396`](../third_party/CameraSync/app/src/main/kotlin/dev/sebastiano/camerasync/data/repository/KableCameraRepository.kt#L363-L396)). | Document gives the **exact seven bytes** and the pairing-state disconnect caveat ([`PROTOCOL_EN.md:30-36`](../third_party/ILCE7M3ExternalGps/PROTOCOL_EN.md#L30-L36)); abandoned source does not implement EE01. |
| Modern initial flow | **Exact initial sequence:** observe DD01, DD30=`01`, DD31=`01`, then read DD32/DD33/DD21 ([`SonyConnectionDelegate.kt:209-301`](../third_party/CameraSync/app/src/main/kotlin/dev/sebastiano/camerasync/vendors/sony/SonyConnectionDelegate.kt#L209-L301)). | Document lists DD01 and orders DD30 then DD31 for protocol `>=65`, but never instructs subscribing to DD01 and omits DD32/DD33 ([`PROTOCOL_EN.md:40-78`](../third_party/ILCE7M3ExternalGps/PROTOCOL_EN.md#L40-L78)); source implements none of DD01/DD30/DD31. |
| DD21 bit and 91/95 selection | **Exact.** Byte 4 mask `0x02`, 91/95 selection, and default-to-95 fallback match ([`SonyProtocol.kt:22-26,181-203,246-250`](../third_party/CameraSync/app/src/main/kotlin/dev/sebastiano/camerasync/vendors/sony/SonyProtocol.kt#L181-L203)). | Document is **exact** ([`PROTOCOL_EN.md:57-66`](../third_party/ILCE7M3ExternalGps/PROTOCOL_EN.md#L57-L66)); source's read helper drops one trailing byte and requires the resulting length to be exactly six, so it only happens to fit the observed seven-byte A7C II response ([`CameraBle.h:119-142`](../third_party/ILCE7M3ExternalGps/src/CameraBle.h#L119-L142)). |
| DD11 bytes and endianness | **Exact.** 91/95 sizes, header, flags, signed scaled coordinates, UTC timestamp, padding, and signed big-endian timezone/DST fields match ([`SonyProtocol.kt:181-243`](../third_party/CameraSync/app/src/main/kotlin/dev/sebastiano/camerasync/vendors/sony/SonyProtocol.kt#L181-L243)). | Protocol document's 95-byte example and offset table are **exact** ([`PROTOCOL_EN.md:76-103`](../third_party/ILCE7M3ExternalGps/PROTOCOL_EN.md#L76-L103)); production source contradicts it as detailed below. |
| Write behavior | DD11 uses write-with-response and retries at most three times ([`SonyConnectionDelegate.kt:112-151`](../third_party/CameraSync/app/src/main/kotlin/dev/sebastiano/camerasync/vendors/sony/SonyConnectionDelegate.kt#L112-L151)); retries are a policy, not A7C II protocol proof. | Source requests a response, but passes the packet's payload-length field as the transport byte count ([`CameraBle.h:144-170`](../third_party/ILCE7M3ExternalGps/src/CameraBle.h#L144-L170)), truncating the packet. |
| Cleanup | **Exact:** DD31=`00`, then DD30=`00` ([`SonyConnectionDelegate.kt:307-341`](../third_party/CameraSync/app/src/main/kotlin/dev/sebastiano/camerasync/vendors/sony/SonyConnectionDelegate.kt#L307-L341)). | Document recommends clearing each control but gives no cleanup order ([`PROTOCOL_EN.md:68-74`](../third_party/ILCE7M3ExternalGps/PROTOCOL_EN.md#L68-L74)); source has no control cleanup. |
| Executable test evidence | Sony UUID, packet, flow/order, capability, and cleanup unit tests pass; examples include byte-order/UTC tests ([`SonyProtocolTest.kt:156-379`](../third_party/CameraSync/app/src/test/kotlin/dev/sebastiano/camerasync/vendors/sony/SonyProtocolTest.kt#L156-L379)) and mocked DD30/DD31/DD11 order tests ([`SonyConnectionDelegateTest.kt:63-234`](../third_party/CameraSync/app/src/test/kotlin/dev/sebastiano/camerasync/vendors/sony/SonyConnectionDelegateTest.kt#L63-L234)). They test assumptions, not a physical camera. | No automated tests; README describes the code as abandoned/reference-only ([`README_EN.md:3-5`](../third_party/ILCE7M3ExternalGps/README_EN.md#L3-L5)). |

## CameraSync assessment

### Why it is preferred

- Its three production layers agree on characteristic roles, packet encoding, and lifecycle: GATT declarations ([`SonyGattSpec.kt:18-68`](../third_party/CameraSync/app/src/main/kotlin/dev/sebastiano/camerasync/vendors/sony/SonyGattSpec.kt#L18-L68)), byte encoding ([`SonyProtocol.kt:181-250`](../third_party/CameraSync/app/src/main/kotlin/dev/sebastiano/camerasync/vendors/sony/SonyProtocol.kt#L181-L250)), and connection flow ([`SonyConnectionDelegate.kt:76-151,156-341`](../third_party/CameraSync/app/src/main/kotlin/dev/sebastiano/camerasync/vendors/sony/SonyConnectionDelegate.kt#L76-L151)).
- Its declared provenance is the decompiled Sony Creators' App plus named public reverse-engineering sources ([`docs/sony/README.md:1-4`](../third_party/CameraSync/docs/sony/README.md#L1-L4)); this is stronger than an unexplained constant but is not independent A7C II hardware evidence.
- Its DD11 encoder matches the local implementation field for field, including a UTC timestamp and separate standard/DST offsets ([`SonyProtocol.kt:187-243`](../third_party/CameraSync/app/src/main/kotlin/dev/sebastiano/camerasync/vendors/sony/SonyProtocol.kt#L187-L243)).
- Its source and mocked unit tests cover failures and lifecycle, not only a packet example, and the selected Sony tests passed locally.

### Caveats and errors

1. **Incorrect EE01 documentation:** `BLE_STATE_MONITORING.md` labels its pairing commands untested and gives six bytes `06 08 01 00 00 00` ([lines 317-321](../third_party/CameraSync/docs/sony/BLE_STATE_MONITORING.md#L317-L321)); CameraSync production source and the A7C II baseline use seven bytes ending in two zeros ([`SonyProtocol.kt:259`](../third_party/CameraSync/app/src/main/kotlin/dev/sebastiano/camerasync/vendors/sony/SonyProtocol.kt#L259)).
2. **Incorrect advertisement-tag notation:** the same document says tags are `<tag> <00> <data>` ([line 342](../third_party/CameraSync/docs/sony/BLE_STATE_MONITORING.md#L342)), while its own `22 EF 00` examples and parser-derived bit table place the value second and reserved byte third ([lines 344-365](../third_party/CameraSync/docs/sony/BLE_STATE_MONITORING.md#L344-L365)).
3. **Omitted advertisement protocol version:** `DATETIME_GPS_SYNC.md` calls the two bytes after device type “Reserved” ([lines 12-15](../third_party/CameraSync/docs/sony/DATETIME_GPS_SYNC.md#L12-L15)), while production parses the first as protocol version and treats only the second as reserved ([`SonyCameraVendor.kt:92-104`](../third_party/CameraSync/app/src/main/kotlin/dev/sebastiano/camerasync/vendors/sony/SonyCameraVendor.kt#L92-L104)).
4. **Mislabeled DD11 length fields:** `DATETIME_GPS_SYNC.md` calls `0x005D` and `0x0059` “Total Length” even though those values are payload lengths 93 and 89 and the packets total 95 and 91 bytes ([lines 109-142](../third_party/CameraSync/docs/sony/DATETIME_GPS_SYNC.md#L109-L142)); production correctly writes `packetSize - 2` ([`SonyProtocol.kt:198-203`](../third_party/CameraSync/app/src/main/kotlin/dev/sebastiano/camerasync/vendors/sony/SonyProtocol.kt#L198-L203)).
5. **Unverified repeated controls:** production code deliberately calls DD30=`01` and DD31=`01` before every DD11 sync ([`SonyConnectionDelegate.kt:76-92,203-245`](../third_party/CameraSync/app/src/main/kotlin/dev/sebastiano/camerasync/vendors/sony/SonyConnectionDelegate.kt#L76-L92)); its protocol document and the validated local implementation lock/enable once and then stream DD11 packets. This extra sequence is not known to be harmful, but it is not required by the A7C II evidence and should not be copied without a reason.
6. **Timezone API coupling:** the packet timestamp uses the supplied instant, but timezone fields use the host system zone rather than the `ZonedDateTime`'s zone ([`SonyProtocol.kt:187-199`](../third_party/CameraSync/app/src/main/kotlin/dev/sebastiano/camerasync/vendors/sony/SonyProtocol.kt#L187-L199)). That matches a phone using its current zone, but callers constructing timestamps for another zone can get inconsistent fields.
7. **Unit tests are not physical-camera proof:** the compatibility list includes A7C II for general connectivity, but no checked-in result demonstrates CameraSync writing A7C II EXIF; retain the local live run as the authority.
8. **MTU 158 is only compatible/unverified for A7C II:** the delegate requests it and tests the constant ([`SonyConnectionDelegate.kt:21-39`](../third_party/CameraSync/app/src/main/kotlin/dev/sebastiano/camerasync/vendors/sony/SonyConnectionDelegate.kt#L21-L39), [`SonyConnectionDelegateTest.kt:53-58`](../third_party/CameraSync/app/src/test/kotlin/dev/sebastiano/camerasync/vendors/sony/SonyConnectionDelegateTest.kt#L53-L58)), while CoreBluetooth successfully sent the A7C II packet without exposing an application MTU setting.

## ILCE7M3ExternalGps assessment

### Useful document-level facts

- The raw advertisement company/device fields, protocol threshold 65, DD/EE UUIDs, pairing payload, DD21 bit, ordered DD30/DD31 requirement, and DD11 offset table agree with the baseline, except that the table incorrectly groups the version byte and reserved byte together as a two-byte version field ([`PROTOCOL_EN.md:1-103`](../third_party/ILCE7M3ExternalGps/PROTOCOL_EN.md#L1-L103)).
- Its example coordinate/time packet is an especially useful secondary test vector: encoding latitude `20.077731`, longitude `110.3332775`, `2020-11-05 04:02:42 UTC`, standard offset `+480` minutes, and zero DST with the local encoder reproduces the documented 95 bytes exactly.
- It provides older A7 III context and explains that DD30/DD31 appeared with newer firmware/protocol `>=65`, but that is cross-model context, not proof of A7C II behavior.

### Critical source contradictions

1. `sendPayload` is a 95-byte template whose first two bytes encode payload length 93 ([`CameraBle.h:51-72`](../third_party/ILCE7M3ExternalGps/src/CameraBle.h#L51-L72)), but `WriteLocationPayload` passes `sendPayload[1]`—93 or 89—as the BLE transport length ([`CameraBle.h:144-170`](../third_party/ILCE7M3ExternalGps/src/CameraBle.h#L144-L170)); this drops the last two bytes from both the required 95- and 91-byte packets.
2. When timezone data is omitted, source changes the length field to `0x59` but leaves byte 5 at the template's `0x03`; the protocol document and A7C II baseline require byte 5 to become `0x00` ([`PROTOCOL_EN.md:88-90`](../third_party/ILCE7M3ExternalGps/PROTOCOL_EN.md#L88-L90)).
3. Source never writes timezone or DST offsets, so its timezone-present form can only report zero offsets regardless of the GPS/device zone ([`CameraBle.h:51-72,144-170`](../third_party/ILCE7M3ExternalGps/src/CameraBle.h#L51-L72)).
4. Source declares only DD21 and DD11 and therefore omits DD01 notification, DD30/DD31 modern setup, DD32/DD33 reads, and DD31/DD30 cleanup ([`CameraBle.h:36-43,265-291`](../third_party/ILCE7M3ExternalGps/src/CameraBle.h#L36-L43)); Git history confirms source commit `23b3a98954c75db0497b1175a87ea600aa45ddd1` was declared unmaintained before documentation-only commit `e7b9300ec2526cd5378d3b8394741a4087948739` added the newer endpoints.
5. Source converts signed latitude/longitude directly from `double` to `unsigned long` ([`ILCE7M3ExternalGps.ino:97-104`](../third_party/ILCE7M3ExternalGps/src/ILCE7M3ExternalGps.ino#L97-L104)); negative southern/western coordinates are not portably converted to the required signed 32-bit representation.
6. The document's advertisement table labels raw bytes 4-5 as one protocol-version field ([`PROTOCOL_EN.md:10-18`](../third_party/ILCE7M3ExternalGps/PROTOCOL_EN.md#L10-L18)); the sample and A7C II parser establish byte 4 as version and byte 5 as reserved.
7. The document's final sentence says the “packet length” becomes 89 when timezone fields are omitted ([`PROTOCOL_EN.md:104`](../third_party/ILCE7M3ExternalGps/PROTOCOL_EN.md#L104)); 89 is the payload-length field, while the on-wire packet must be 91 bytes.
8. The source transmits once per second ([`CameraBle.h:8-9`](../third_party/ILCE7M3ExternalGps/src/CameraBle.h#L8-L9), [`ILCE7M3ExternalGps.ino:150-154`](../third_party/ILCE7M3ExternalGps/src/ILCE7M3ExternalGps.ino#L150-L154)), which is not a protocol contradiction but should not replace the validated project's 30-second policy without testing.

The document can therefore corroborate individual packet facts, but the source receives the critical-contradiction cap and is not an executable reference for A7C II.

## Ranked recommendations by protocol area

### Modern A7C II location session

1. **CameraSync production source — preferred.** Complete DD01/DD30-DD33/DD21/DD11 lifecycle, correct cleanup, and passing unit tests; repeated DD30/DD31 writes remain an explicit caveat.
2. **ILCE7M3ExternalGps protocol document — secondary only.** Correct DD30/DD31 order and threshold, but no DD32/DD33 or complete executable modern flow.
3. **All other libraries — not covered.**

### DD11 packet encoding

1. **CameraSync `SonyProtocol.kt` — preferred.** Complete 91/95-byte implementation with tests and exact A7C II baseline agreement.
2. **ILCE7M3ExternalGps `PROTOCOL_EN.md` — useful test vector.** Byte table is correct, but its accompanying source is critically truncated and internally inconsistent.
3. **All other libraries — not covered.**

### General Sony BLE metadata

1. **CameraSync — broadest reference.** Covers FF/CC/DD/EE services, advertisement identity/version, and status tags, subject to the documentation corrections below.
2. **alpharemote — preferred specifically for A7C II FF00 remote compatibility.** It names A7C II among physically confirmed remote models, but explicitly does not implement geotagging.
3. **freemote — useful older-model advertisement and FF00 source.** It includes an A7 III physical test and status-bit parsing; CameraSync cites it, so it is not independent corroboration of CameraSync's copied claims.
4. **ILCE7M3ExternalGps document — useful raw advertisement/DD metadata for older A7 III firmware.**
5. **Other adjacent remote projects — derivative or narrower, with no location evidence.**

## Safe reuse boundaries

Safe to reuse from CameraSync after retaining local tests:

- Sony manufacturer ID, camera device type, protocol-version offset/threshold.
- DD/EE UUID declarations and access directions.
- DD21 byte-4 mask.
- DD11 91/95-byte layout, big-endian integer encoding, UTC timestamp, and standard/DST offset split.
- Initial DD01 → DD30 → DD31 → DD32 → DD33 → DD21 → DD11 flow.
- DD31 then DD30 cleanup and write-with-response behavior.

Do not copy without separate justification:

- CameraSync's six-byte EE01 documentation, advertisement tag-order notation, omitted protocol-version field, mislabeled DD11 length fields, repeated DD30/DD31 writes, system-zone coupling, retry policy, or MTU 158 assumption.
- Any executable DD11/session code from ILCE7M3ExternalGps.
- Location conclusions from FF00-only remote libraries or from PTP/USB libraries.

## Unresolved claims

- Whether re-writing DD30/DD31 before every DD11 improves keep-alive behavior or is merely redundant on A7C II.
- Exact DD01 notification payload/state semantics during an active A7C II location session.
- Whether MTU 158 is required or merely preferred on Android for A7C II.
- Which older/newer Sony models accept the same 91/95-byte forms and lifecycle; A7C II evidence must not be generalized automatically.
- Whether CameraSync has unpublished physical Sony location tests; no checked-in model-specific evidence establishes this.

## Verification performed

- Screened all 16 immediate `third_party/*/` projects by exact DD service/characteristic identifiers; only CameraSync and ILCE7M3ExternalGps matched.
- Compared the local encoder with the ILCE7M3ExternalGps documented vector; the complete 95-byte hex packet matched.
- Ran CameraSync's selected Sony unit tests with Android Studio's JBR and the local Android SDK: `./gradlew app:testDebugUnitTest --tests 'dev.sebastiano.camerasync.vendors.sony.SonyProtocolTest' --tests 'dev.sebastiano.camerasync.vendors.sony.SonyGattSpecTest' --tests 'dev.sebastiano.camerasync.vendors.sony.SonyConnectionDelegateTest'`; Gradle reported `BUILD SUCCESSFUL`.
- Performed no BLE writes, camera mutation, or production-code change during this research.
