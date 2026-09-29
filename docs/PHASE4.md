# Phase 4: capture and analyze exam questions

## Goal

Use the on-screen button as the trigger that will later be replaced or supplemented by Huawei Watch:

```text
D7WN live JPEG -> copy current complete frame -> OpenAI Responses API -> result screen
```

The analysis reports only:

1. Whether at least one complete question was read successfully, as exactly one Chinese character: `是` or `否`.
2. If the result is `是`, the final answer for every complete visible question, identified by question number when multiple questions are present.

It does not transcribe the questions, options, or reasoning steps.

## Implementation

- The API Key is entered on iPhone and stored in iOS Keychain with `WhenUnlockedThisDeviceOnly` protection.
- The key is not written to source code, Git, capture files, app logs, or UserDefaults.
- The model name is configurable; the initial default is `gpt-4o-mini`.
- A button press copies one complete in-memory JPEG and also saves that exact frame locally.
- The JPEG is sent as a Base64 data URL in a Responses API `input_image` item with `detail: high`.
- `text.format` uses a strict JSON Schema for the `是`/`否` read status and final-answer string.
- The request sets `store: false`.
- Build 0.4 used URLSession with cellular access allowed. Physical testing verified that this did not force cellular: iOS eventually selected the camera AP as the default public route and the upload failed.
- Build 0.5 replaces URLSession transport with a Network.framework TLS/TCP connection whose required interface type is cellular.
- The camera TCP connection separately requires Wi-Fi.
- Cloud requests never fall back to Wi-Fi. If a cellular path is unavailable, analysis fails explicitly.
- The app verifies `NWConnection.currentPath` before sending and displays the verified route.
- The result screen shows the captured image, `是`/`否`, final answers when readable, errors, and retry for the same frame.

Official references:

- <https://developers.openai.com/api/docs/guides/images-vision>
- <https://developers.openai.com/api/docs/guides/structured-outputs>
- <https://developers.openai.com/api/reference/cli/resources/responses/methods/create>

## Status

- **VERIFIED on build 0.4**: an OpenAI request succeeds after Wi-Fi is disabled and the phone switches to cellular.
- **VERIFIED on build 0.4**: merely allowing cellular in URLSession does not keep the upload on cellular while the D7WN AP remains joined.
- **VERIFIED on build 0.5**: a cellular-bound Network.framework connection reaches OpenAI while the camera remains live over Wi-Fi.
- **VERIFIED on build 0.6**: the strict `是`/`否` response, real worksheet capture, answer display, and simultaneous live camera plus cellular analysis work on the physical phone.
- **UNKNOWN**: answer accuracy across a broad range of worksheet layouts and image conditions.
- **OUT OF SCOPE**: Huawei Watch triggering.

## Physical test

1. Install build 0.6.0 and join `Nax_5cf097da7367` with cellular data enabled.
2. Open the key icon, enter an OpenAI API Key, and save.
3. Start live video and place a worksheet in view.
4. Tap **CAPTURE & ANALYZE**.
5. Confirm that the result page displays the same captured frame.
6. Wait until iOS shows the Wi-Fi icon, then run another analysis without disconnecting from the AP.
7. Confirm the app shows `Camera route: Wi-Fi (verified)` and `Cloud route: Cellular (verified)`.
8. Disable cellular data and retry. Confirm analysis fails explicitly instead of using Wi-Fi.
9. Confirm the result is exactly `是` or `否`; when it is `是`, compare every final answer against the page.
