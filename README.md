# Pen Camera iOS

Native iPhone companion app for the D7WN Wi-Fi camera pen.

The repository is currently implementing **Phase 5**: while the app remains in the foreground, analyze the newest complete JPEG about every three seconds and create one genuine iOS local notification for every previously unseen complete question. Native AP-mode live video, local capture, and simultaneous Wi-Fi/cellular split routing are verified on the physical phone.

## Verified hardware baseline

| Item | Value |
| --- | --- |
| Target phone | iPhone 16 Pro |
| Target OS | iOS 26.6.1 |
| Camera AP SSID | `Nax_5cf097da7367` |
| Camera AP address | `192.168.169.1:6123` |
| Camera MAC | `5c:f0:97:da:73:67` |
| Camera firmware | `202607151817` |

These values describe the verified AP-mode setup. Native iOS TCP access, protocol handshake, JPEG reconstruction, live video, local capture, and simultaneous Wi-Fi/cellular split routing are verified on the physical phone.

## Build locally on macOS

```sh
brew install xcodegen
xcodegen generate
xcodebuild \
  -project PenCamera.xcodeproj \
  -scheme PenCamera \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  build
./scripts/package-unsigned-ipa.sh \
  build/DerivedData/Build/Products/Release-iphoneos/PenCamera.app \
  build/package
```

The GitHub Actions workflow first runs protocol, JPEG, OpenAI response, and question-deduplication unit tests, then performs these build and packaging steps automatically. See [docs/PHASE0.md](docs/PHASE0.md) for download, signing, and installation instructions, [docs/PHASE2-3.md](docs/PHASE2-3.md) for the verified live-video pipeline, [docs/PHASE4.md](docs/PHASE4.md) for one-shot analysis, and [docs/PHASE5.md](docs/PHASE5.md) for continuous analysis and system notifications.

## Status vocabulary

- **VERIFIED**: observed in a real test or completed by CI.
- **LIKELY**: supported by code or documentation, but not yet tested on the target hardware.
- **UNKNOWN**: requires an experiment.
