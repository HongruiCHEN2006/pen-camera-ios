# Pen Camera iOS

Native iPhone companion app for the D7WN Wi-Fi camera pen.

The repository is currently at **Phase 0**: prove that a Windows-authored SwiftUI project can be built on GitHub's macOS runner, packaged as an unsigned/re-signable IPA, signed with a free Apple Account by Sideloadly on Windows, and installed over USB on the target iPhone.

## Verified hardware baseline

| Item | Value |
| --- | --- |
| Target phone | iPhone 16 Pro |
| Target OS | iOS 26.6.1 |
| Camera AP SSID | `Nax_5cf097da7367` |
| Camera AP address | `192.168.169.1:6123` |
| Camera MAC | `5c:f0:97:da:73:67` |
| Camera firmware | `202607151817` |

These values describe the verified AP-mode setup. They do not prove iOS socket access yet.

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

The GitHub Actions workflow performs these steps automatically. See [docs/PHASE0.md](docs/PHASE0.md) for download, signing, and installation instructions.

## Status vocabulary

- **VERIFIED**: observed in a real test or completed by CI.
- **LIKELY**: supported by code or documentation, but not yet tested on the target hardware.
- **UNKNOWN**: requires an experiment.

