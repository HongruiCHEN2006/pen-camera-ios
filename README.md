# Pen Camera iOS

Native iPhone companion app for the D7WN Wi-Fi camera pen.

The repository includes a deliberately simple Even G2 companion. While the native app remains in the foreground, it uses the original black-screen detection flow, reads the D7WN stream over the camera's Wi-Fi, sends OpenAI traffic over cellular, and exposes completed question batches through a loopback-only HTTP relay. Every batch first shows brief question openings with approximate answers, followed by complete questions and detailed answers in one continuous scroll document. The original iOS notification pop-ups remain enabled.

## Verified hardware baseline

| Item | Value |
| --- | --- |
| Target phone | iPhone 16 Pro |
| Target OS | iOS 26.6.1 |
| Camera AP SSID | `Nax_5cf097da7367` |
| Camera AP address | `192.168.169.1:6123` |
| Camera MAC | `5c:f0:97:da:73:67` |
| Camera firmware | `202607151817` |

The camera link is Wi-Fi/TCP rather than Bluetooth. The G2 home view shows the
verified stream connection state. It also shows a battery percentage only when
the camera's device-info response contains a recognized 0–100 battery field;
otherwise the battery line is omitted.

Before an answer arrives, G2 also shows the black-frame verdict, upload state,
and current batch image count. Once answers arrive, status and help text disappear
and the full display is reserved for compact quick answers followed by complete
questions and answers. The right-temple app menu remains available; click then
long-press on the left temple clears the locally displayed answers.

While a batch is uploading, G2 temporarily prioritizes a four-line status view:
black-frame verdict, upload started, upload finished (including success/failure),
and the current batch image count. This status also appears over previously stored
answers and returns to the answer document after the phone resets the upload cycle.

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

The GitHub Actions workflow first runs protocol, JPEG, OpenAI response, relay, and question-deduplication unit tests, then performs these build and packaging steps automatically. See [docs/PHASE0.md](docs/PHASE0.md) for download, signing, and installation instructions, [docs/PHASE2-3.md](docs/PHASE2-3.md) for the verified live-video pipeline, [docs/PHASE4.md](docs/PHASE4.md) for one-shot analysis, and [docs/PHASE5.md](docs/PHASE5.md) for the Even G2 flow.

## Even G2 companion

The plugin lives in `EvenG2/`. Build and package it on Windows with:

```powershell
cd EvenG2
npm install
npm run pack
```

Upload `EvenG2/Pen-Camera-G2.ehpk` as a private build. Open **Pen Camera** from the glasses menu once, then keep the native iPhone app in the foreground while capturing. The plugin keeps running in the Even App WebView on iOS and polls `127.0.0.1:8765`; it does not use the camera Wi-Fi for internet access.

There are no capture modes or glasses camera controls. Swipe to scroll, click to move down approximately one screen, and double-click to exit. The contextual menu provides up/down scrolling, local answer clearing, and refresh.

## Status vocabulary

- **VERIFIED**: observed in a real test or completed by CI.
- **LIKELY**: supported by code or documentation, but not yet tested on the target hardware.
- **UNKNOWN**: requires an experiment.
