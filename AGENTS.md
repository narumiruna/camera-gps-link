# Agent Instructions

- If any program source file exceeds 1000 lines, split it immediately.
- Use `justfile` for common project commands:
  - `just --list` to see available recipes.
  - `just check` for the full local Python + iOS verification gate.
  - `just py-check` for Python-only lint/type/test.
  - `just ios-check` for iOS smoke/typecheck/project lint/build checks.
  - `just ios-open` to open the iOS Xcode project.
  - `just ios-console` to launch the installed iOS app on the default USB device and attach console output.
- Prefer targeted `just` recipes over repeating long shell commands.
- Do not run `just location-write` unless the user explicitly asks to write GPS data to the camera.

## Gotchas

- Symptom: macOS BLE commands launched through SSH fail or hang with CoreBluetooth authorization `notDetermined`.
  Cause: Bluetooth TCC approval is tied to a GUI-launched responsible process.
  Fix: launch the BLE command from local Terminal or a signed local app and approve Bluetooth access before retrying.
- Symptom: an iOS foreground camera attempt can remain busy even when stage timeout code exists.
  Cause: session preparation cancels an attempt started too early, or failure handling switches to unbounded background reconnect solely because Background is configured.
  Fix: begin the foreground timeout after transient cleanup and preserve attempt origin when choosing bounded failure versus background retry.

## References

- When implementation help is needed, such as information about other camera models, inspect the code in `third_party/`.
- Check `third_party/references.md` first; if it lacks the required information, search `third_party/`.
- After reading third-party code, determine whether the information is useful; if it is, record it in `third_party/references.md`.
- Write each note in `third_party/references.md` on a separate line, briefly describing its purpose, relative source path, file name, and line numbers.
- If third-party source code contains incorrect information, briefly document the error and why it is incorrect in `third_party/references.md`.
