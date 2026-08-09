# Third-party Sony Protocol Reliability Research Plan

## Goal

Identify which library under `third_party/` is the most reliable reference for the Sony A7C II (`ILCE-7CM2`) BLE location/geotag protocol, and document exactly which claims are trustworthy, uncertain, or incorrect.

## Context

- The user has confirmed that the current implementation works correctly on a physical Sony A7C II.
- The A7C II baseline is recorded in `docs/a7c2-ble-map.md`, `src/sonygeotag/sony_protocol.py`, `src/sonygeotag/sony_location.py`, `ios/CameraGPSLink/CameraGPSLink/SonyProtocol.swift`, and `ios/CameraGPSLink/CameraGPSLink/CameraBLEManager.swift`.
- The completed exact-identifier screen found direct DD location material only in `third_party/CameraSync/` and `third_party/ILCE7M3ExternalGps/`; all 16 top-level libraries are classified in `docs/third-party-sony-protocol-reliability.md`.
- `third_party/references.md` now records 38 useful source, caveat, scope, and error notes, and `.gitignore` explicitly allows that file to be tracked while keeping third-party checkouts ignored.

## Assumptions

- “Reliable information” means information relevant to BLE location linking and geotag transfer, not general USB, PTP/IP, Wi-Fi remote-control, or image-transfer behavior.
- The research will be static and read-only; it will not run `just location-write` or perform any other camera write.
- A7C II results will be treated as ground truth only for the behavior actually exercised or observed, not as proof that every Sony model behaves identically.

## Non-Goals

- Do not change production Python or iOS code.
- Do not test unsupported camera models or claim cross-model compatibility.
- Do not rank libraries by popularity, code volume, or recency alone.

## Plan

- [x] Build an atomic A7C II ground-truth matrix from the baseline files, covering advertisement parsing, service and characteristic UUIDs, EE01/DD30/DD31 setup order, DD21 capability parsing, DD11 packet size/layout/endianness/time handling, write behavior, update loop, and DD31/DD30 cleanup; the report's matrix gives a local line citation and evidence level for every item.
- [x] Inventory every immediate project under `third_party/`, recording its pinned commit, claimed camera models, transport/protocol scope, and relevance; an automated revision audit matched all 16 report rows to their current nested-repository HEADs, and the exact DD identifier screen found only the two direct candidates.
- [x] Deep-read the relevant implementations, tests, protocol documents, and commit history; `third_party/references.md` contains 38 one-line notes with purpose, relative path, file name, and line numbers.
- [x] Check internal documentation/source/test consistency and provenance; the report separates live A7C II evidence, decompiled Creators' App claims, mocked tests, copied remote-control material, and the ILCE documentation-only updates after source maintenance stopped.
- [x] Compare extracted claims against the A7C II matrix; the direct-candidate table and detailed assessments record exact matches, compatible claims, contradictions, packet-length/flag/sign errors, and operation-order/lifecycle differences.
- [x] Rank the libraries for modern A7C II session flow, DD11 packet encoding, and general Sony BLE metadata; CameraSync is preferred for both location areas, while alpharemote is preferred only for A7C II FF00 remote evidence.
- [x] Write `docs/third-party-sony-protocol-reliability.md` and `third_party/references.md`; both include trustworthy facts, source/model caveats, unresolved claims, and explicit incorrect-information records.
- [x] Verify all evidence and deliverables: 97 local report links/line anchors resolve, all 16 revisions match, 38 reference notes have existing paths and line citations, selected CameraSync Sony tests report `BUILD SUCCESSFUL`, `just py-check` passes with 48 tests, and `git diff --check` passes without production-code changes.

## Completion Checklist

- [x] Every one of the 16 `third_party/*/` libraries is classified as direct, adjacent, or out of scope with source evidence and a pinned revision.
- [x] Every ranked protocol claim is traceable through the ground-truth and direct-candidate matrices to A7C II baseline and third-party citations.
- [x] The report names CameraSync as the preferred location reference, provides area-specific rankings, and explains all discovered caveats and contradictions.
- [x] `third_party/references.md` contains concise source notes and explicitly records CameraSync and ILCE7M3ExternalGps errors.
- [x] No BLE writes or camera mutations were performed, and the only repository changes are documentation, the completed plan, `third_party/references.md`, and the `.gitignore` exception needed to track it.
