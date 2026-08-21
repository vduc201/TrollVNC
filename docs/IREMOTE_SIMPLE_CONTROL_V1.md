# iRemote Simple Control Protocol v1

## Transport

- Device TCP port `46753`, bound only to `127.0.0.1`; Windows reaches it through Apple usbmux.
- One persistent UTF-8 connection per iPhone `DeviceSession`.
- Commands and responses are LF-terminated lines; CRLF input is accepted.
- Maximum command line: 4096 UTF-8 bytes. Idle/read and write timeout: 120 seconds. App output is capped at 4096 records and 2 MiB.
- Existing REST control on device port `46752` remains unchanged for compatibility/diagnostics.

## Handshake and authentication

```text
C: IREMOTE 1
S: OK IREMOTE 1
C: AUTH <existing-per-device-control-token>
S: OK AUTH
```

Invalid authentication returns `ERR AUTH_INVALID` and closes the connection. Commands sent before authentication return `ERR AUTH_REQUIRED`. The token is the existing TrollVNC Control API token and is never logged.

## Commands

```text
PING                         -> OK PONG
STATUS                       -> OK STATUS VERSION=<v> VNC=<state> CAPTURE=<mode> ACTIVE=<backend> WIFI=<state>
WIFI GET                     -> OK WIFI ON|OFF|UNKNOWN|UNSUPPORTED
WIFI ON|OFF                  -> verified OK WIFI ON|OFF
APP LIST                     -> BEGIN APPS <count>, APP records, END APPS
APP OPEN <bundleId>          -> OK APP OPEN <bundleId>
CAPTURE GET                  -> OK CAPTURE CONFIGURED=<mode> ACTIVE=<backend> FPS=<n> DROPPED=<n>
CAPTURE SET AUTO|FAST|SYSTEM_FULL|UIKIT_FULL
CAPTURE REQUIRE_FULL <8..300 seconds>
VNC RESTART                  -> OK VNC RESTARTING (only when supervisor-managed)
```

App records are `APP<TAB>bundleId<TAB>name<TAB>type`. Fields escape backslash as `\\`, tab as `\t`, carriage return as `\r`, and line feed as `\n`; decoding is deterministic left-to-right.

Stable errors include: `AUTH_REQUIRED`, `AUTH_INVALID`, `INVALID_COMMAND`, `UNKNOWN_COMMAND`, `WIFI_UNSUPPORTED`, `WIFI_CHANGE_FAILED`, `WIFI_VERIFY_FAILED`, `APP_LIST_FAILED`, `APP_LIST_TOO_LARGE`, `APP_NOT_INSTALLED`, `APP_LAUNCH_FAILED`, `INVALID_CAPTURE_MODE`, `INVALID_LEASE`, `CAPTURE_UNAVAILABLE`, and `VNC_RESTART_FAILED`.

Wi-Fi, installed apps, capture switching/AUTO leases, and service recovery call the same `IRDeviceServices`, `CaptureManager`, and supervisor implementation used by REST. The Simple Control connection runs outside the VNC/capture queues and remains open until USB disconnect, idle timeout, authentication failure, or intentional close.
