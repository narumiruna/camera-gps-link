# Sony BLE location profile specification

This document is the fail-closed contract shared by the Python and iOS implementations. Model names describe compatibility evidence; they never select protocol operations.

## Descriptor requirements

Resolution starts only after every requested Sony service has completed characteristic discovery. A characteristic counts only when it belongs to service `8000DD00-DD00-FFFF-FFFF-FFFFFFFFFFFF` and exposes the required property.

| Characteristic | Required property | Use |
| --- | --- | --- |
| DD11 | write with response | Location packet |
| DD21 | read | 91/95-byte negotiation |
| DD30 | write with response | Modern lock |
| DD31 | write with response | Modern enable |
| DD01 | notify or indicate | Optional modern status |
| DD32 | read | Optional time-correction state |
| DD33 | read | Optional area-adjustment state |

A write-without-response-only DD11, DD30, or DD31 is unsupported. A UUID found under another service does not count.

## Profile truth table

| Discovery | Protocol | DD11/DD21 | DD30/DD31 | Registry | Result | Permitted before approval |
| --- | ---: | --- | --- | --- | --- | --- |
| incomplete | any | any | any | any | unsupported | none |
| complete | any | missing/wrong property | any | any | unsupported | identity and approved read-only evidence only |
| complete | any | valid | only one or wrong property | any | unsupported | identity and approved read-only evidence only |
| complete | `>= 65` | valid | both valid | not blocked | modern | verified identity may continue; otherwise approval is required |
| complete | `>= 65` | valid | absent | any | unsupported/inconsistent | identity and approved read-only evidence only |
| complete | `< 65` | valid | absent | not blocked | legacy | approval is required unless exact evidence is verified |
| complete | `< 65` | valid | present | any | unsupported/inconsistent | identity and approved read-only evidence only |
| complete | unknown | valid | both valid | not blocked | modern experimental | identity and approved read-only evidence only |
| complete | unknown | valid | absent | any | unsupported | identity and approved read-only evidence only |
| complete | any | valid | any | unsupported | unsupported | identity and approved read-only evidence only |

Optional DD01/DD32/DD33 absence does not invalidate an otherwise complete profile and never changes packet size.

## Identity and confidence

A compatibility key contains normalized model, firmware when readable, advertisement protocol version, and resolved profile. `LE-` is removed from model names for matching. Exact registry evidence can mark a key verified or unsupported; all other executable matches are experimental. Unknown firmware always receives session-only approval.

An experimental location request must stop after read-only identity and descriptor discovery. It prints a purpose-specific key derived from normalized model, readable firmware, advertisement protocol version, and the full resolved execution profile; a repeated Python request needs both `--allow-experimental --approval-key <key>`. Location-sync keys cannot authorize EE01 pairing, and unreadable firmware cannot receive a reusable Python approval. `pair-init` has its own purpose-specific key and runs only while the camera is explicitly on its pairing screen, after system bonding and before a separate location connection. iOS uses volatile on-screen confirmation bound to the same profile and action purpose. Unsupported entries cannot be overridden. Approval occurs before DD01 subscription, DD30/DD31, DD11, or EE01.

Direct reconnect and CoreBluetooth restoration may load private remembered context only as a comparison candidate. Fresh CC0A/CC0B identity and complete descriptors must match the stored key before it can regain verified confidence. Missing or mismatched context is experimental and cannot write before approval.

## DD21 negotiation truth table

DD21 is accepted only at exactly 6 or 7 bytes.

| Condition | Result |
| --- | --- |
| Prefix is `06 10 00 9c`, flags byte is `02`, all tail bytes are `00` | 95-byte DD11 with timezone/DST |
| Prefix is `06 10 00 9c`, flags byte is `00`, all tail bytes are `00` | 91-byte DD11 without timezone/DST |
| Wrong length | negotiation failure; no DD11 |
| Wrong prefix | negotiation failure; no DD11 |
| Any flag bit other than `0x02` | negotiation failure; no DD11 |
| Any nonzero reserved tail byte | negotiation failure; no DD11 |
| Missing value or read error | negotiation failure; no DD11 |

Malformed approved DD21 bytes may be shown in a transient sanitized snapshot for research, but they must not be promoted to evidence or interpreted automatically.

## Session and compensation truth table

Ordinary location sessions never send EE01. Pairing initialization is a distinct explicit action and connection: complete the OS bond, run EE01 while the camera remains on its pairing screen, disconnect, return to shooting mode, and only then start the location session. No command combines EE01 with DD30/DD31/DD11.

| Profile/state | Setup | DD11 permitted | Compensation |
| --- | --- | --- | --- |
| unsupported or awaiting approval | none | no | none |
| legacy | read and validate DD21 | after valid DD21 | none; never touch DD30/DD31 |
| modern | optional DD01; DD30=`01`; DD31=`01`; optional DD32/DD33; strict DD21 | after controls and valid DD21 | see below |
| DD30 write fails/cancels/times out after dispatch | stop | no | attempt DD30=`00` because the acknowledgement may be lost after commit |
| DD30 confirmed, DD31 write fails/cancels/times out after dispatch | stop | no | attempt DD31=`00`, then DD30=`00` |
| DD30 and DD31 succeed, later failure/cancel/timeout | stop | no further writes | DD31=`00`, then DD30=`00` |
| disconnect prevents compensation | stop | no | report explicit incomplete-cleanup diagnostic |

Cleanup cannot be disabled. DD01 is stopped after control compensation. DD11 uses write with response; a failed DD11 ends the bounded session and triggers compensation. Photos used as evidence must be captured while the bounded location window is active; post-cleanup capture is not accepted as proof that the camera retained the fix.

## Privacy contract

Compatibility evidence and exported diagnostics may contain model, firmware, protocol version, approved DD characteristic/property metadata, strict DD21 bytes, packet size, confidence, sanitized operation names/order, and cleanup status. They must not contain peripheral identifiers, Bluetooth addresses, manufacturer-data tails, credentials, opaque/unknown payloads, raw DD11 coordinates, or photos.
