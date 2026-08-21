# Screen capture architecture

## Baseline and modes

The known-good rollback point is commit `d84727189295c226f14ddf080651ec5e9cc3802d`, tagged `iremote-agent-baseline-ci-pass`. Its original `ScreenCapturer` remains intact and is used by `FastCaptureBackend`.

`CaptureManager` is the sole capture entry point for the VNC server. It supports:

- `fast`: the original `CARenderServerRenderDisplay` → `IOSurface` path;
- `full`: a runtime-checked `_UICreateScreenUIImage` path intended to include process-external visible system UI where the target iOS runtime permits it;
- `auto`: currently selects `fast` conservatively. Automatic switching remains disabled until physical comparison data establishes a reliable signal and safe dwell/cooldown values.

Select a mode when launching the existing server:

```sh
trollvncserver -p 5901 -X fast
trollvncserver -p 5901 -X full
trollvncserver -p 5901 -X auto
```

The default is `fast`, preserving baseline behavior.

## Full backend availability and limits

The full backend resolves `_UICreateScreenUIImage` dynamically. If the symbol is absent, selecting `full` fails explicitly; no fabricated frame and no silent fallback are produced. A successful compile cannot prove that the symbol is available or that its output includes keyboards, alerts, sheets, notifications, or other process-external layers on a particular iOS release.

The full backend captures actual screen images only. It may scale the captured image into the fixed portrait framebuffer expected by the existing rotation and RFB pipeline, but it does not crop, stretch missing regions, paint system UI, or synthesize keyboard pixels.

Protected or DRM-controlled content is not supported.

## Physical comparison gate

Before enabling automatic switching, install the feature build on the target iPhone and compare `fast` and `full` with the same VNC client while showing:

- Home Screen and a normal app;
- normal, password, and numeric keyboards;
- alerts, system sheets, and the copy/paste menu;
- portrait, landscape-left, and landscape-right.

For each mode record correctness, capture latency, observed FPS, CPU/memory impact, and stability. Do not mark full-screen coverage as passed until those checks run on a physical iPhone.

## Realtime behavior

Both backends feed `CMSampleBuffer` frames into the unchanged TrollVNC framebuffer and RFB path. RFB remains the only realtime stream transport. The existing bounded in-flight update policy remains responsible for dropping stale work when clients cannot keep up.
