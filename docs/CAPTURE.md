# Screen capture architecture — Phase B2

## Scope and rollback

The known-good rollback point is `d84727189295c226f14ddf080651ec5e9cc3802d` (`iremote-agent-baseline-ci-pass`). Phase B remains available at `cd3cdf`. This phase changes capture providers only; RFB is still the sole realtime transport and AUTO/Wi-Fi/App Launcher work is intentionally excluded.

## Explicit test modes

- `fast`: unchanged `CARenderServerRenderDisplay` → `IOSurface` baseline.
- `uikit_full`: the former `full` backend, using the runtime-resolved `_UICreateScreenUIImage` symbol. The legacy CLI value `full` remains an alias for configuration compatibility.
- `system_full`: a separate provider that dynamically loads XCTest/XCUIAutomation and calls `XCUIScreen.mainScreen.screenshot.image`. It performs a real screenshot probe before starting and fails explicitly if the framework, selector, daemon session, or returned image is unavailable.

```sh
trollvncserver -p 5901 -X fast
trollvncserver -p 5901 -X uikit_full
trollvncserver -p 5901 -X system_full
```

The default stays `fast`. There is no AUTO mode in this test build.

## SYSTEM_FULL runtime constraint

Apple exposes screenshots through `XCUIScreen`, but WebDriverAgent obtains them while running as an XCTest test runner and communicates with the XCTest daemon. A TrollStore daemon may not have that active runner session. Therefore SYSTEM_FULL is marked available only after a real probe succeeds on the device. Failure is reported as `capture.backend=system_full ... initialization=failed reason=...`; it never substitutes FAST or UIKIT_FULL.

This build deliberately does not bundle or reuse unknown binaries, does not add an MJPEG server, does not fake pixels, and does not claim passcode-keypad coverage before physical validation.

## Backpressure and metrics

SYSTEM_FULL has one serial capture queue and at most one screenshot in flight. Display ticks arriving while it is busy are dropped, preventing stale-frame queue growth. Every five seconds it logs `durationMs`, frame dimensions, `captureFPS`, `droppedFrames`, and `frameFailures`. Logs contain no screenshot pixels or passcode content.

## Physical-device acceptance matrix

Test the three modes separately with the same VNC client and record visibility, latency, FPS, CPU/memory, and stability for:

- Home Screen and a normal app;
- normal, password, numeric, and lock-screen passcode keypads;
- alerts, system sheets, copy/paste menu, Control Center, and notifications;
- portrait, landscape-left, and landscape-right.

Protected/DRM content is out of scope. Mark SYSTEM_FULL successful only when the physical device shows complete keypad pixels and remote input coordinates still align.
