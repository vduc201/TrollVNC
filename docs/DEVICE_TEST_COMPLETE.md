# iRemote Agent physical-device validation

Record the iPhone model and iOS version. Install only the package from the linked successful feature-branch CI run. Do not enter real credentials in the test fields.

## Install and baseline

- [ ] Install `iRemoteAgent.tipa` with TrollStore.
- [ ] Launch TrollVNC; confirm no immediate crash.
- [ ] In TrollVNC settings, select **Capture Mode → FAST (Original)** and restart TrollVNC.
- [ ] Connect the same VNC client used for the known-good baseline.
- [ ] Confirm Home Screen, normal app, tap, drag, swipe, scroll, keyboard, clipboard, orientation, and reconnect still behave as before.

## FAST versus FULL comparison

For each row, test FAST first, then select **Capture Mode → FULL (Experimental)**, restart TrollVNC, reconnect the same VNC client, and test again. If FULL causes a launch or server failure, return to FAST and collect logs.

| Visible UI | FAST | FULL | Notes |
| --- | --- | --- | --- |
| Home Screen complete | [ ] | [ ] | |
| Normal app complete | [ ] | [ ] | |
| Normal keyboard visible | [ ] | [ ] | |
| Password keyboard visible | [ ] | [ ] | Use dummy text; never share it. |
| Numeric keyboard visible | [ ] | [ ] | |
| System alert visible | [ ] | [ ] | |
| System sheet visible | [ ] | [ ] | |
| Copy/paste menu visible | [ ] | [ ] | |
| Portrait correct | [ ] | [ ] | |
| Landscape-left correct | [ ] | [ ] | |
| Landscape-right correct | [ ] | [ ] | |

## FULL interaction and stability

- [ ] Tap coordinates match the displayed target.
- [ ] Long press works.
- [ ] Drag works without a coordinate offset.
- [ ] Swipe works.
- [ ] Scroll works.
- [ ] Letters, numbers, symbols, and modifier sequences work.
- [ ] Clipboard works Windows → iPhone and iPhone → Windows.
- [ ] Disconnect/reconnect does not crash or leave input stuck.
- [ ] Ten minutes of active use shows no obvious growing delay or memory warning.

## AUTO smoke check

AUTO is intentionally conservative in this build and begins on FAST; it does not yet infer missing system layers.

- [ ] Select **Capture Mode → AUTO (Conservative)** and restart TrollVNC.
- [ ] Confirm it behaves like FAST and does not crash.

## Logs to collect on failure

Use the app's **View Logs** action first. The underlying files are:

```text
/tmp/trollvnc-stderr.log
/tmp/trollvnc-stdout.log
```

They may also appear as `/private/tmp/trollvnc-stderr.log` and `/private/tmp/trollvnc-stdout.log`. Report the selected capture mode, iPhone model, iOS version, exact failing screen, whether the VNC connection stayed alive, and the relevant log excerpt. Do not include passwords, typed text, clipboard contents, auth secrets, or screen contents.

## Result gate

Phase B passes only when FAST remains baseline-correct and FULL is physically shown to improve the missing visible system UI without breaking orientation, input mapping, or stability. If FULL is unavailable or does not capture the password keyboard, report that outcome; do not mark it passed and do not enable automatic switching.
