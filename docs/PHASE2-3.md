# Phases 2 and 3: native live JPEG pipeline

## Scope

Build 0.3.0 performs the AP-mode sequence already used by the working Python client:

1. Open TCP `192.168.169.1:6123`.
2. Send Nax command `115` (live motion).
3. Send JSON code `501` (connect).
4. Send AP JSON code `502`, inner code `4` (base information).
5. Send AP JSON code `502`, inner code `3` (open video).
6. Exchange command `100` heartbeats.
7. Parse 20-byte little-endian Nax headers from arbitrary TCP fragments.
8. Feed command `1` payloads to a JPEG SOI/EOI assembler.
9. Keep the newest complete, decodable JPEG in memory and display it.
10. Save the newest JPEG to the app Documents directory when **CAPTURE CURRENT FRAME** is tapped. File sharing is enabled so captures can be inspected under **Files > On My iPhone > Pen Camera**.

The JSON byte fixtures in the unit tests were generated with the repository's Python protocol classes at the fixed Unix timestamp `1720000000`. This validates Swift compatibility byte-for-byte without claiming physical-camera success.

## Status before physical test

- **VERIFIED**: Windows Python can receive D7WN live video through the same AP endpoint and protocol sequence.
- **VERIFIED**: physical iPhone native TCP access to the AP endpoint succeeds.
- **VERIFIED after CI passes**: Swift request bytes match Python fixtures; TCP fragmentation and JPEG marker tests pass; the arm64 unsigned IPA builds.
- **VERIFIED on iPhone 16 Pro / iOS 26.6.1**: firmware `202607151817` accepts the complete native Swift handshake.
- **VERIFIED on iPhone 16 Pro / iOS 26.6.1**: live JPEG frames display correctly on iPhone.
- **VERIFIED on iPhone 16 Pro / iOS 26.6.1**: the on-screen capture button preserves a real current frame.
- **OUT OF SCOPE**: OpenAI upload, API-key storage, cellular-path verification, and Huawei Watch commands.

## Physical test

1. Install build 0.3.0 through Sideloadly.
2. Join `Nax_5cf097da7367` in iOS Settings.
3. Open Pen Camera and tap **Start Live**.
4. Record the last state shown if video does not appear.
5. After the frame counter increases, tap **CAPTURE CURRENT FRAME**.
6. Confirm that the app reports a timestamped `.jpg` filename.
7. Open **Files > On My iPhone > Pen Camera** and verify that the JPEG contains the expected camera frame.

The physical result must be recorded before native live video is labeled **VERIFIED**.
