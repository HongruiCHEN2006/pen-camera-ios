# Phase 1: D7WN AP-mode TCP experiment

## Purpose

Test one unknown at a time on the physical iPhone. This phase does not claim video support merely because a TCP socket connects.

## Baseline

- **VERIFIED on Windows**: the D7WN AP endpoint is `192.168.169.1:6123`.
- **VERIFIED on Windows**: the Python client can use this endpoint for live JPEG video.
- **UNKNOWN on iPhone**: an iOS app can reach this endpoint while joined to `Nax_5cf097da7367`.

## Build 0.2.0 experiment

1. In iOS Settings, join `Nax_5cf097da7367`.
2. Return to Pen Camera.
3. Tap **Test TCP 6123**.
4. Allow Local Network access if iOS asks.
5. Record the exact result, interface, latency, and any error.

Success verifies only:

```text
iPhone app → iOS local network permission/routing → 192.168.169.1:6123 TCP accept
```

It does not yet verify:

- the Nax/V720 live-motion command (`115`)
- JSON connection or device-info responses
- the open-video command
- packet framing or heartbeats
- JPEG reconstruction or preview
- simultaneous cellular upload while connected to the camera AP

## Next gate

Only after the TCP probe succeeds will the protocol encoder and response parser be ported from the verified Python implementation.

