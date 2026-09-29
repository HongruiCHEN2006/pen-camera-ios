# Phase 0: Windows to iPhone delivery path

## Goal

Prove this exact path before camera development begins:

```text
Windows development
        ↓
private GitHub repository
        ↓
GitHub macOS 26 runner / Xcode 26.6
        ↓
unsigned, re-signable IPA
        ↓
Sideloadly on Windows / free Apple Account
        ↓ USB
iPhone 16 Pro / iOS 26.6.1
```

## What the workflow produces

The `Build unsigned IPA` workflow builds a real iPhoneOS `arm64` application with signing disabled. Its artifact contains:

- `PenCamera-unsigned.ipa`
- `build-metadata.txt` with the bundle ID, version, SHA-256, and signature status
- `binary-architecture.txt`

An unsigned IPA cannot be installed directly. Sideloadly must sign it for the connected iPhone using the Apple Account before installation.

## Windows prerequisites

1. Keep the iPhone connected by USB and keep **Trust This Computer** enabled.
2. Install the current Sideloadly release from its official website.
3. Follow Sideloadly's current Windows prerequisites. At the time this phase was designed, its official instructions required the web-download editions of iTunes and iCloud rather than Microsoft Store editions.
4. Keep the same Apple Account and bundle ID for later refreshes.

Do not place an Apple Account password, app-specific password, OpenAI API key, signing certificate, or provisioning profile in this repository or in GitHub Actions.

## Download the IPA

1. Open this repository on GitHub.
2. Open **Actions** and select the newest successful **Build unsigned IPA** run.
3. Download the `PenCamera-unsigned-<commit>` artifact.
4. Extract the ZIP. The IPA is inside the extracted folder.
5. Optionally compare its SHA-256 with `build-metadata.txt`:

   ```powershell
   Get-FileHash .\PenCamera-unsigned.ipa -Algorithm SHA256
   ```

## Install with Sideloadly

1. Connect and unlock the iPhone by USB.
2. Open Sideloadly and confirm that the iPhone appears as the target device.
3. Drag `PenCamera-unsigned.ipa` into Sideloadly.
4. Enter the Apple Account used for free signing, then start the install.
5. If iOS asks, enable Developer Mode and trust the developer identity under the current Settings path shown by iOS.
6. Launch **Pen Camera** and tap **Test button**. The counter must increment.

## Free-account constraints

Apple's free Personal Team provisioning is temporary. Expect the installed app and its provisioning profile to expire after seven days, after which it must be signed and installed again. Free accounts also have limits on devices, active apps, and registered App IDs.

## Acceptance criteria

- **VERIFIED**: GitHub reports a successful `macos-26` / Xcode 26.6 build.
- **VERIFIED**: artifact metadata reports `signature=unsigned` and the binary includes `arm64`.
- **VERIFIED**: Sideloadly signs and installs the IPA through USB.
- **VERIFIED**: the app launches on the iPhone 16 Pro running iOS 26.6.1 and the test button increments.

Until the last two checks are performed on the physical phone, installation compatibility remains **UNKNOWN**.

## Explicitly out of scope for Phase 0

- connecting to `192.168.169.1:6123`
- parsing or displaying the JPEG stream
- cellular upload while joined to the camera AP
- OpenAI API calls or key storage
- Huawei Watch communication

