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
- URLSession allows cellular, expensive, and constrained network paths and waits for connectivity.
- The result screen shows the captured image, progress, structured questions, errors, and retry for the same frame.

Official references:

- <https://developers.openai.com/api/docs/guides/images-vision>
- <https://developers.openai.com/api/docs/guides/structured-outputs>
- <https://developers.openai.com/api/reference/cli/resources/responses/methods/create>

## Status before physical test

- **VERIFIED after CI passes**: request construction, image encoding, strict-schema configuration, response parsing, error parsing, Swift compilation, and unsigned IPA packaging.
- **UNKNOWN**: an OpenAI request succeeds while the phone remains joined to the D7WN AP.
- **UNKNOWN**: iOS selects cellular for the public API route while preserving the camera's Wi-Fi TCP connection.
- **UNKNOWN**: the physical worksheet image is sharp enough to read all intended questions and options.
- **OUT OF SCOPE**: solving questions and Huawei Watch triggering.

## Physical test

1. Install build 0.4.0 and join `Nax_5cf097da7367`.
2. Open the key icon, enter an OpenAI API Key, and save.
3. Start live video and place a worksheet in view.
4. Tap **CAPTURE & ANALYZE**.
5. Confirm that the result page displays the same captured frame.
6. Record whether the request succeeds while still joined to the camera AP.
7. Compare every reported question number, clarity flag, and option against the page.
