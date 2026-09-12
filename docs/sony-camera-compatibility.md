# Sony camera location compatibility

Support is qualified by exact model, firmware, advertisement protocol version, and discovered BLE location profile.
Matching a known GATT shape is **experimental**, not proof that a camera accepts GPS data.
The current plan limits physical-camera qualification to A7C II: its row records passing post-refactor Python, iOS development, and Release-equivalent iOS qualification foreground writes. The exact proven identity is promoted for public Release; signed public Release validation remains pending.
Every other row remains an automated-fixture candidate with no physical test or promotion required.

The first public iOS App Store release is intentionally limited to Sony Alpha 7C II (`ILCE-7CM2`).
Other model fixtures and research tools do not constitute public iOS support.
The ordinary public Release registry contains only the exact A7C II `2.01` identity proven by the Release-optimized qualification build. Qualification and public Release policies remain fail-closed for every other identity and provide no experimental override.
See [`plans/2026-08-31_ios-a7c2-only-app-store-release-plan.md`](plans/2026-08-31_ios-a7c2-only-app-store-release-plan.md) for the accepted release decision and verification gates.

| Model | Firmware | Advertisement version | Profile | DD21 / packet | Python foreground | iOS foreground | Background | Evidence |
| --- | --- | ---: | --- | --- | --- | --- | --- | --- |
| A7C II (`ILCE-7CM2`) | `2.01` | `101` (`0x65`) | modern | `06 10 00 9c 02 00 00` / 95 | verified HEIF EXIF | Debug and Qualification HEIF EXIF verified; signed public Release pending | available by product decision; unverified | [`ilce-7cm2-2.01.md`](compatibility/ilce-7cm2-2.01.md), [`a7c2-ble-map.md`](a7c2-ble-map.md) |
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

## Current validation scope

1. Maintain the A7C II Python foreground EXIF regression in the external [SonyGeoTag repository](https://github.com/narumiruna/sony-geotag) and run the iOS foreground EXIF check here.
2. Validate generic modern/legacy resolution, execution safety, compensation, and experimental approval through automated Python fixtures in SonyGeoTag and Swift fixtures in this repository.
3. Do not collect snapshots, perform writes, or request EXIF evidence from non-A7C II physical cameras under the current plan; keep every such row unverified.

Read-only snapshot and experimental-write tooling remains available from SonyGeoTag for future separately scoped qualification.
Any real write still requires separate explicit authorization and approved coordinates.
