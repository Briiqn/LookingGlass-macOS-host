# Looking Glass host for macOS guests

A macOS port of the Looking Glass host application, for a macOS (x86_64) VM
with a passed-through GPU under QEMU/KVM, viewed with the regular Linux
`looking-glass-client`.

| Feature  | How                                                                 |
|----------|---------------------------------------------------------------------|
| Video    | ScreenCaptureKit, only changed areas are copied (KVMFR damage rects) |
| Cursor   | position and shape sent separately, drawn by the client             |
| Input    | KVMFR input over LGMP, injected with Quartz events (no SPICE needed) |
| Clipboard| KVMFR clipboard over LGMP: text, images and files, both directions  |
| Memory   | ivshmem through the LGIVSHMEM kext (separate project)       |

The protocol is unchanged, so an unmodified client of the same version works
(built and tested against `B7-826-g236efcb155`).

## Layout

- `common/src/platform/darwin/` — the macOS platform layer of `lg_common`.
  `ivshmem.c` maps the shared memory through the LGIVSHMEM kext.
- `host/platform/Darwin/capture/ScreenCaptureKit/` — capture, cursor and
  damage tracking.
- `host/platform/Darwin/src/` — `platform.c` (startup, cursor warping),
  `input.m` (event injection), `clipboard.m` (NSPasteboard).
- `host/src/input.c`, `host/src/clipboard.c` — the LGMP side of input and
  clipboard, C ports of the Windows IDD transports, enabled on macOS with
  `LG_HOST_INPUT` / `LG_HOST_CLIPBOARD`.
- `host/platform/Darwin/package/` — app bundle, login item and scripts.

## Building and installing

Requirements: the Xcode Command Line Tools and CMake, plus the LGIVSHMEM kext
loaded in the guest.

```sh
host/platform/Darwin/package/install.sh
```

This builds into `build-macos/`, installs `~/Applications/LookingGlassHost.app`
and a login item (`~/Library/LaunchAgents/local.lgmac.LookingGlassHost.plist`)
that starts it at login and restarts it if it exits. The log is
`~/Library/Logs/LookingGlassHost.log`.

The app needs two permissions in System Settings > Privacy & Security:

- **Screen & System Audio Recording**, to capture the screen.
- **Accessibility**, to inject mouse and keyboard input.

macOS ties the permissions to the app's signature. With an ad-hoc signature
every rebuild is a new app and needs them granted again; to avoid that, run
`create-signing-cert.sh` once and trust the certificate it creates for code
signing. `install.sh` then signs with it.

To reset the permissions:

```sh
tccutil reset ScreenCapture local.lgmac.LookingGlassHost
tccutil reset Accessibility local.lgmac.LookingGlassHost
```

### Packaging for Release

To create standalone release assets (`LookingGlassHost.dmg`, `LookingGlassHost-Installer.pkg`, and `LookingGlassHost.zip`) for distribution:

```sh
host/platform/Darwin/package/build-release.sh [output-dir]
```

## Options

The host reads `~/looking-glass-host.ini`.

| Option        | Default | Description                                     |
|---------------|---------|-------------------------------------------------|
| `sck:display` | 0       | CGDirectDisplayID to capture, 0 = main display |
| `sck:maxFps`  | 0       | Capture at most this many frames per second, 0 = the display refresh rate |

## VM and client setup notes

- **USB:** macOS only creates 15 ports per xHCI controller and QEMU numbers the
  USB 3 ports first, so with more than 15 ports USB 2 devices (mice, the QEMU
  USB devices) disappear. Use e.g. `-device qemu-xhci,p2=11,p3=4`.
- **Audio:** macOS has no driver for QEMU's HDA codec; `-device usb-audio`
  works out of the box.
- **Mouse:** with LGMP input the client sends absolute positions; turn off
  pointer acceleration in macOS anyway for SPICE fallback.
- **Client:** `win:jitRender=yes` makes the cursor noticeably more direct, and
  `input:captureOnFocus=no` gives the seamless mouse between host and guest.
- **App Nap:** the host is a background app (`LSUIElement`); it opts out of App
  Nap and runs its threads at user-interactive QoS, otherwise macOS throttles
  its timers by hundreds of milliseconds.
