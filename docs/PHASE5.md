# Phase 5: Even G2 question delivery

## Goal

While the native Pen Camera app stays in the foreground:

```text
D7WN TCP stream over forced Wi-Fi
    -> OpenAI over forced cellular
    -> complete, previously unseen questions
    -> loopback-only HTTP relay on 127.0.0.1:8765
    -> Even Hub plugin
    -> short answers followed by full questions in a continuous G2 document
```

The native app and the Even plugin do not share process memory. The native app owns camera TCP, cellular OpenAI calls, API-key storage, course selection, notifications, and the original black-screen detection flow. The Even plugin only owns answer presentation, persisted reading position, a small contextual menu, and temple scrolling.

## Routing

- Camera traffic remains forced to the Wi-Fi interface at `192.168.169.1:6123`.
- OpenAI traffic remains forced to the cellular interface, because the camera AP has no internet connection.
- The Even plugin reads results from `127.0.0.1`, which is phone-local and does not use either external route.
- The relay binds only to loopback and returns CORS headers required by the Even App WebView.

## Question content

The structured `opening` field now contains the complete reconstructed printed question, not a shortened opening phrase. It includes all readable conditions, formulas, code, table values, text-representable diagram labels, and answer choices. The answer remains separate.

The plugin uses `@evenrealities/pretext` to measure the G2 firmware's glyph widths and fixed line height. Internally it produces screen-sized viewports, but presents them as one continuous document without question/page navigation or page-number UI.

The first viewport also reports the camera stream connection state. Battery is
optional because the D7WN protocol has no verified battery command: the native
app forwards a percentage only if a device-info JSON response exposes a known
battery field with a value from 0 through 100.

Before answers arrive, the same viewport reports the current black-frame verdict,
upload state, and number of images collected in the current batch. As soon as an
answer batch is available, all device/status/footer text is hidden and only the
quick answers followed by the complete questions and answers remain.

## Controls

- Swipe down/up: scroll the continuous answer document.
- Single click: advance approximately one screen.
- Double-click: show the system exit confirmation.
- Contextual menu: scroll up/down, clear locally stored answers, or refresh.

## Physical test

1. Install native build `0.21.0` and the private `Pen-Camera-G2.ehpk` build.
2. Open **Pen Camera** from the glasses menu. Leave it waiting for the phone relay.
3. On iPhone, join `Nax_5cf097da7367`, keep cellular data enabled, and open the native Pen Camera app.
4. Start the live stream, then tap **Start G2 Analysis**.
5. Capture a question and cover the lens for the two black-frame confirmations.
6. Confirm the glasses show every brief answer first, followed by the complete questions and detailed answers.
7. Use temple swipe/click controls to scroll the continuous document without page-number navigation.
8. Confirm OpenAI still succeeds while the iPhone reports that the camera Wi-Fi has no internet connection.

## Status

- **VERIFIED**: native AP live video and forced Wi-Fi/cellular split routing on the physical iPhone.
- **VERIFIED after CI passes**: Swift relay types, full-question prompt, existing parsers, and iOS build.
- **VERIFIED locally after `npm run pack`**: Even plugin TypeScript, Vite build, manifest, and `.ehpk` packaging.
- **UNKNOWN until physical test**: Even App access to the loopback relay while its WebView is backgrounded behind the native app.
