# Isolated iOS CI build

## Source and scope

This workflow builds the official [OwnGoalStudio/TrollVNC](https://github.com/OwnGoalStudio/TrollVNC) source. The CI setup was prepared from upstream branch `main` at commit `170c784da388439fb33092a1524d8279a079d62d`.

The workflow uses the repository's existing `bootstrap` target. That target produces the TrollStore-style `.tipa` package and preserves the application's existing bundle name, bundle identifier, executable names, resources, and entitlements. The output filename is changed only after a successful build and validation.

The other existing package schemes (`default`, `rootless`, and `roothide`) produce jailbreak `.deb` packages and are intentionally outside this workflow.

## Build environment and dependencies

The job runs entirely on GitHub's `macos-14` hosted runner and selects Xcode 16.2. It prints `sw_vers`, `xcodebuild -version`, and the active developer directory, then verifies that Xcode exposes an `iphoneos` SDK with `xcrun`.

The job installs only the tools used by the upstream build:

- GNU Make (`gmake`)
- `ldid-procursus` for the project's existing pseudo-signing process
- `xcbeautify`, used by the Theos/Xcode project build integration
- `roothide/theos`, checked out with submodules
- Theos iPhoneOS 16.5 SDK, matching the repository's device target

Nothing is installed on the developer's Mac. Homebrew and SDK setup occur only on the disposable GitHub runner.

## Exact build command

From the repository root, CI executes:

```bash
source devkit/bootstrap.sh
FINALPACKAGE=1 gmake clean package
```

This invokes the existing Makefiles and the existing `devkit/before-package.sh` and `devkit/after-package.sh` packaging hooks.

## Run manually

1. Push this repository, including `.github/workflows/build-ios.yml`, to GitHub.
2. Open the repository's **Actions** tab.
3. Select **Build iRemoteAgent test package**.
4. Choose **Run workflow**, select the desired branch, and confirm.
5. Wait for the `Build and validate TrollVNC bootstrap package` job to succeed.

## Download the artifact

Open the completed workflow run and download the artifact named `iRemoteAgent-test` from the **Artifacts** section. The artifact contains:

```text
iRemoteAgent.tipa
```

GitHub retains it for 14 days. The archive is uploaded only after compilation, packaging, and validation all succeed.

## Validation

Before upload, the workflow verifies that:

- the ZIP-compatible `.tipa` archive passes `unzip -t`;
- `Payload/` contains exactly one `.app` bundle;
- the application has a valid `Info.plist`;
- `CFBundleExecutable` names an existing executable file;
- the executable is a 64-bit Mach-O containing `arm64`;
- `otool -L` can inspect its runtime dependencies;
- `ldid -e` can extract non-empty, valid plist entitlements.

Any failed check stops the job, and no placeholder package is uploaded.

## Common build errors and limitations

- **Xcode 16.2 is unavailable:** the hosted runner image changed or no longer contains that Xcode version. Update the runner/Xcode pair only after confirming compatibility with the project's Makefiles and SDK target.
- **iPhoneOS SDK lookup fails:** Xcode selection is incomplete or the hosted image is missing the platform. Check the version-reporting and SDK-verification steps.
- **Theos SDK download fails:** GitHub or the SDK release may be temporarily unavailable, or the workflow token may be rate-limited. Retry the job and inspect the `Install the project iOS SDK` log.
- **`ldid` is missing:** check the Homebrew `ldid-procursus` installation step and runner architecture.
- **Compilation cannot find private frameworks or headers:** confirm the checked-out upstream commit still includes its `PrivateFrameworks/` and `include-spi/` inputs and still targets Theos iPhoneOS 16.5.
- **No `.tipa` or multiple `.tipa` files are found:** the upstream bootstrap packaging output changed. Inspect `devkit/after-package.sh` before changing the artifact selection.
- **Entitlement validation fails:** the executable was not pseudo-signed by the existing packaging process. Do not bypass this check or upload the package.

This pipeline does not install or launch the package on an iPhone, so it does not claim physical-device or runtime testing. It also does not build the jailbreak `.deb` variants or any Windows application.
