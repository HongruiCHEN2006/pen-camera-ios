# Phase 4: capture and analyze exam questions

## Goal

Use the on-screen button as the trigger that will later be replaced or supplemented by Huawei Watch:

```text
D7WN live JPEG -> copy current complete frame -> OpenAI Responses API -> result screen
```

The analysis reports only:

1. Printed question number.
2. Whether the question and its options were read clearly.
3. Visible option labels and text.

It does not solve the question or select an answer.

## Implementation

- The API Key is entered on iPhone and stored in iOS Keychain with `WhenUnlockedThisDeviceOnly` protection.
- The key is not written to source code, Git, capture files, app logs, or UserDefaults.
- The model name is configurable; the initial default is `gpt-4o-mini`.
- A button press copies one complete in-memory JPEG and also saves that exact frame locally.
- The JPEG is sent as a Base64 data URL in a Responses API `input_image` item with `detail: high`.
- `text.format` uses a strict JSON Schema for question number, clarity, and options.
- The request sets `store: false`.
- Build 0.4 used URLSession with cellular access allowed. Physical testing verified that this did not force cellular: iOS eventually selected the camera AP as the default public route and the upload failed.
- Build 0.5 replaces URLSession transport with a Network.framework TLS/TCP connection whose required interface type is cellular.
- The camera TCP connection separately requires Wi-Fi.
- Cloud requests never fall back to Wi-Fi. If a cellular path is unavailable, analysis fails explicitly.
- The app verifies `NWConnection.currentPath` before sending and displays the verified route.
- The result screen shows the captured image, progress, structured questions, errors, and retry for the same frame.

Official references:

- <https://developers.openai.com/api/docs/guides/images-vision>
- <https://developers.openai.com/api/docs/guides/structured-outputs>
- <https://developers.openai.com/api/reference/cli/resources/responses/methods/create>

## Status

- **VERIFIED on build 0.4**: an OpenAI request succeeds after Wi-Fi is disabled and the phone switches to cellular.
- **VERIFIED on build 0.4**: merely allowing cellular in URLSession does not keep the upload on cellular while the D7WN AP remains joined.
- **VERIFIED after build 0.5 CI passes**: request construction, image encoding, route-policy construction, HTTP/1.1 encoding, Content-Length/chunked response parsing, Swift compilation, and unsigned IPA packaging.
- **UNKNOWN until build 0.5 physical test**: a cellular-bound Network.framework connection reaches OpenAI while the camera remains live over Wi-Fi.
- **UNKNOWN**: the physical worksheet image is sharp enough to read all intended questions and options.
- **OUT OF SCOPE**: solving questions and Huawei Watch triggering.

## Physical test

1. Install build 0.5.0 and join `Nax_5cf097da7367` with cellular data enabled.
2. Open the key icon, enter an OpenAI API Key, and save.
3. Start live video and place a worksheet in view.
4. Tap **CAPTURE & ANALYZE**.
5. Confirm that the result page displays the same captured frame.
6. Wait until iOS shows the Wi-Fi icon, then run another analysis without disconnecting from the AP.
7. Confirm the app shows `Camera route: Wi-Fi (verified)` and `Cloud route: Cellular (verified)`.
8. Disable cellular data and retry. Confirm analysis fails explicitly instead of using Wi-Fi.
9. Compare every reported question number, clarity flag, and option against the page.
