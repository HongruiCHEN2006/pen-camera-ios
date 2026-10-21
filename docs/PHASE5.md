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

The native app and the Even plugin do not share process memory. The native app owns camera TCP, cellular OpenAI calls, API-key storage, course selection, notifications, burst capture, and black-screen detection. The Even plugin owns presentation, persisted reading position, the low-frame-rate preview, a contextual menu, and temple input.

## Routing

- Camera traffic remains forced to the Wi-Fi interface at `192.168.169.1:6123`.
- OpenAI traffic remains forced to the cellular interface, because the camera AP has no internet connection.
- The Even plugin reads results from `127.0.0.1`, which is phone-local and does not use either external route.
- The relay binds only to loopback and returns CORS headers required by the Even App WebView.

## Question content

The structured `opening` field now contains the complete reconstructed printed question, not a shortened opening phrase. It includes all readable conditions, formulas, code, table values, text-representable diagram labels, and answer choices. The answer remains separate.

The plugin uses `@evenrealities/pretext` to measure the G2 firmware's glyph widths and fixed line height. Internally it produces screen-sized viewports, but presents them as one continuous document without question/page navigation or page-number UI.

## Controls

- With no answers, left click then left long-press: open the mutually exclusive mode selector.
- In manual mode, left click: collect three frames across one second.
- In manual mode, left double-click: finish the batch and upload all collected frames together.
- With answers visible, left click then left long-press: clear all current answers.
- Swipe down/up: scroll the continuous answer document.
- Single click: advance approximately one screen.
- Right double-click: show the system exit confirmation.
- Contextual menu: switch mode, select either capture mode, clear answers, or refresh.

## Physical test

1. Install native build `0.18.0` and the private `Pen-Camera-G2.ehpk` build.
2. Open **Pen Camera** from the glasses menu. Leave it waiting for the phone relay.
3. On iPhone, join `Nax_5cf097da7367`, keep cellular data enabled, and open the native Pen Camera app.
4. Start the live stream, then tap **Start G2 Analysis**.
5. Capture a question and cover the lens for the two black-frame confirmations.
6. Confirm the glasses automatically open the complete question and answer.
7. Use temple swipe/click controls to visit every page and every received question.
8. Confirm OpenAI still succeeds while the iPhone reports that the camera Wi-Fi has no internet connection.

## Status

- **VERIFIED**: native AP live video and forced Wi-Fi/cellular split routing on the physical iPhone.
- **VERIFIED after CI passes**: Swift relay types, full-question prompt, existing parsers, and iOS build.
- **VERIFIED locally after `npm run pack`**: Even plugin TypeScript, Vite build, manifest, and `.ehpk` packaging.
- **UNKNOWN until physical test**: Even App access to the loopback relay while its WebView is backgrounded behind the native app.
