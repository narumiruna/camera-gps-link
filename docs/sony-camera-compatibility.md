# Sony camera location compatibility

Support is qualified by exact model, firmware, advertisement protocol version, and discovered BLE location profile. Matching a known GATT shape is **experimental**, not proof that a camera accepts GPS data. The A7C II row records the historical hardware baseline plus a passing post-refactor Python foreground write; full promotion remains pending until iOS produces matching GPS EXIF.

| Model | Firmware | Advertisement version | Profile | DD21 / packet | Python foreground | iOS foreground | Background | Evidence |
| --- | --- | ---: | --- | --- | --- | --- | --- | --- |
| A7C II (`ILCE-7CM2`) | `2.01` | `101` (`0x65`) | modern | `06 10 00 9c 02 00 00` / 95 | verified HEIF EXIF | implementation complete; write/EXIF pending | unverified | [`ilce-7cm2-2.01.md`](compatibility/ilce-7cm2-2.01.md), [`a7c2-ble-map.md`](a7c2-ble-map.md) |
| A7 III (`ILCE-7M3`) | unknown | unknown | unresolved; legacy candidate only when `<65` and controls absent | unknown | unverified | unverified | unverified | none |
| A7 IV (`ILCE-7M4`) | unknown | unknown | unresolved; modern candidate | unknown | unverified | unverified | unverified | none |
| A6700 (`ILCE-6700`) | unknown | unknown | unresolved; modern candidate | unknown | unverified | unverified | unverified | none |
| A7R V (`ILCE-7RM5`) | unknown | unknown | unresolved | unknown | unverified | unverified | unverified | none |
| A7S III (`ILCE-7SM3`) | unknown | unknown | unresolved | unknown | unverified | unverified | unverified | none |
| A1 (`ILCE-1`) | unknown | unknown | unresolved | unknown | unverified | unverified | unverified | none |
| ZV-E1 (`ZV-E1`) | unknown | unknown | unresolved | unknown | unverified | unverified | unverified | none |
| ZV-E10 II (`ZV-E10M2`) | unknown | unknown | unresolved | unknown | unverified | unverified | unverified | none |

## Labels

- **Historical baseline:** pre-refactor physical evidence established the protocol behavior; it does not substitute for the plan's post-refactor per-platform regressions.
- **Verified:** exact identity/profile has accepted DD11 on the named platform after this refactor and a new JPEG or HEIF image passed the standard EXIF verifier.
- **Experimental:** descriptors and protocol version resolve to an executable profile, but exact identity/profile evidence is incomplete. Explicit approval is required before any subscription or write.
- **Unsupported:** required properties or protocol shape are inconsistent, or an exact registry entry blocks the identity. Approval cannot override this.
- **Unverified:** no physical evidence exists for that row or platform.

Background behavior is never inferred from foreground success. Models not listed above remain unverified.

## Qualification order

1. Re-run A7C II Python and iOS foreground EXIF checks after capability refactoring.
2. Qualify A7 III; keep protocol-`<65` legacy physical status unverified unless that hardware is observed.
3. Qualify A7 IV completely, then A6700 independently.
4. Qualify A7R V, A7S III, A1, ZV-E1, and ZV-E10 II individually.

Use `sonygeotag compatibility-snapshot --target <model> --pair` first. Real writes require separate explicit authorization and approved coordinates.
