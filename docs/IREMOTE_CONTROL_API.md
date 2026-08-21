# iRemoteAgent control protocol v1

## Transport and authentication

The agent listens only on `127.0.0.1:46752` on the iPhone. Windows must discover the physical device with Apple usbmux and open device port `46752`; direct LAN control is not part of the contract. Each HTTP/1.1 request uses a fresh connection and ends with `Connection: close`.

Every `/api/v1/*` request requires `Authorization: Bearer <device-token>`. The token is configured per iPhone in TrollVNC Settings (`Control API Token`, minimum 24 characters), is held only in memory by the Windows client, and is never logged. Missing or invalid credentials return `401`; an unavailable token store returns `503`. VNC passwords and iOS passcode content are not exposed by this API.

Requests and responses use UTF-8 JSON and a bounded `Content-Length`. A success body always contains `"ok": true`; failures contain `"ok": false` and a stable `error` string. Current API version is `1`.

## Endpoints

| Method | Path | Request | Result |
|---|---|---|---|
| GET | `/api/v1/health` | — | readiness, VNC client count, supervisor state, capture telemetry |
| GET | `/api/v1/version` | — | `apiVersion`, `agentVersion` |
| GET | `/api/v1/device` | — | model, name, iOS version, desktop name and ports |
| GET | `/api/v1/capture` | — | configured mode, active backend and telemetry |
| POST | `/api/v1/capture` | see below | updates mode and/or AUTO completeness lease |
| GET | `/api/v1/wifi` | — | `{supported,state,reason?}` |
| POST | `/api/v1/wifi` | `{"enabled":true}` | verified power state |
| GET | `/api/v1/apps` | — | installed app records (`bundleId`, `name`, `type`) |
| POST | `/api/v1/apps/launch` | `{"bundleId":"com.apple.Preferences"}` | launch result |
| POST | `/api/v1/services/vnc/restart` | `{}` | schedules supervised server recovery |
| POST | `/api/v1/services/control/restart` | `{}` | schedules supervised process recovery |

Wi-Fi and installed-app operations use runtime-checked iOS private services. Unsupported iOS builds return an explicit `supported:false` or `503`; the agent never reports success without verifying the operation.

## Capture modes and AUTO

`FAST`, `UIKIT_FULL`, and `SYSTEM_FULL` remain directly selectable for diagnostics. `AUTO` is the default:

- FAST is used for normal realtime capture.
- A client requests completeness with `{"completenessRequired":true,"leaseSeconds":15}`. AUTO changes to SYSTEM_FULL only after geometry/pixel-format validation.
- Minimum SYSTEM_FULL dwell is 8 seconds, switch cooldown is 3 seconds, and a lease is bounded to 8–300 seconds. Lease generations prevent stale timers from oscillating a newer request.
- `UIKIT_FULL` is never selected automatically.
- If SYSTEM_FULL cannot start, capture rolls back to FAST.
- Only the capture producer changes. The RFB server, touch, keyboard and clipboard sessions stay alive; framebuffer/input geometry must match before switching.

Capture responses report `activeBackend`, `captureFPS`, `outputFPS`, `capturedFrames`, `outputAcceptedFrames`, `droppedFrames`, in-flight frames, capture uptime and last delivery duration.

Example:

```http
POST /api/v1/capture HTTP/1.1
Authorization: Bearer <device-token>
Content-Type: application/json
Content-Length: 51

{"completenessRequired":true,"leaseSeconds":15}
```

## Recovery and USB-first client sequence

1. Enumerate USB devices with usbmux and retain the usbmux device ID/UDID mapping.
2. Open device port `46752`, authenticate, and call `/health`, `/version`, then `/device`.
3. Open the configured VNC device port (normally `5901`) through a separate usbmux stream.
4. Keep the last decoded framebuffer visible if VNC drops. Ask `/services/vnc/restart`, wait for the watchdog, then reconnect VNC with bounded exponential backoff.
5. A USB disconnect invalidates both streams. Do not silently fall back to LAN; rediscover the same UDID first.

The legacy line-oriented local control commands remain available for compatibility, but new iRemote functions use the authenticated API.

## Validation state

- SYSTEM_FULL completeness on the physical reference iPhone: **PASSED** (user validation, Phase B2).
- AUTO switching, Wi-Fi, app enumeration/launch, authentication over usbmux, and supervised recovery on physical hardware: **NOT TESTED** until individually verified on a real iPhone.
- FAST and UIKIT_FULL remain preserved; UIKIT_FULL is diagnostic only in AUTO policy.
