# Phase 5: continuous question notifications

## Goal

While the app stays in the foreground:

```text
D7WN latest complete JPEG
    -> OpenAI over forced cellular
    -> complete, previously unseen questions
    -> one real iOS local notification per question
```

Each notification is scheduled with `UNUserNotificationCenter` and an independent `UNNotificationRequest`. Its title contains the question number and its body contains the final answer. This is an operating-system notification—not a custom in-app banner—and it is eligible for Notification Center, sound, and the user's normal iOS notification controls.

## Behavior

- **Start 3s Analysis** requests iOS notification authorization, then starts a foreground-only loop.
- A new request begins no more often than once every three seconds. Requests never overlap. If one request takes longer than three seconds, the next starts after it finishes.
- Each request copies the latest complete in-memory JPEG at the start of that cycle.
- OpenAI returns every visible question, whether it is complete, its internal transcription, and its final answer when complete.
- Incomplete questions never create notifications.
- The internal transcription is used only for duplicate detection and is not shown in the notification or manual result screen.
- Seen complete questions are persisted locally. Matching uses the normalized question number plus normalized or highly similar question text.
- **Clear analyzed-question history** allows the same questions to notify again.
- Moving the app to the background or stopping the camera stops continuous analysis. The app does not claim unsupported continuous background execution.
- Camera traffic remains forced to Wi-Fi, while OpenAI traffic remains forced to cellular.

## Status

- **VERIFIED**: AP live video and forced Wi-Fi/cellular split routing work together on the physical iPhone.
- **VERIFIED after CI passes**: the multi-question strict schema, foreground loop, persistent duplicate detection, and notification scheduling code compile; automated parser and history tests pass.
- **UNKNOWN until physical test**: notification permission, foreground system notification presentation, vibration/sound behavior, multi-question accuracy, and practical three-second cadence on the target iPhone.
- **OUT OF SCOPE**: Huawei Watch control. The two on-screen controls currently simulate its future start and stop commands.

## Physical test

1. Install build 0.7.0 and enable notifications for **Pen Camera** when prompted.
2. Join `Nax_5cf097da7367`, keep cellular data enabled, and start live video.
3. Put one complete numbered question in view, then tap **Start 3s Analysis**.
4. Confirm iOS—not an app-drawn overlay—shows a notification containing the question number and answer. Pull down Notification Center and confirm it is present there.
5. Keep the same question in view for multiple cycles and confirm no duplicate notification appears.
6. Move a different complete question into view and confirm one new notification appears.
7. Show a cropped or unreadable question and confirm it does not notify.
8. Tap **Stop Analysis** and confirm the request count stops increasing.
9. Clear the analyzed-question history, restart, and confirm the earlier question can notify again.
