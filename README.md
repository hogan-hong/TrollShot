# TrollShot

A minimal TrollStore-installable iOS app that exposes a single HTTP endpoint:

```
GET http://<device-ip>:8080/screenshot
```

It returns the current device screen as a JPEG image.

TrollShot is derived from [TrollVNC](https://github.com/OwnGoalStudio/TrollVNC) and therefore licensed under the GNU General Public License v2.

## How it works

1. Uses private `CARenderServerRenderDisplay` to render the display into an `IOSurface`.
2. Uses `IOSurfaceAccelerator` to transfer/convert the surface.
3. Wraps the surface in a `CVPixelBuffer` and encodes it as JPEG via `CoreImage` / `ImageIO`.
4. Serves the JPEG over a tiny HTTP server running inside the app.

No VNC protocol, no HID injection, no remote control.

## Build requirements

- macOS with Xcode Command Line Tools
- [Theos](https://theos.dev/) installed (`$THEOS` set)
- iOS SDK (e.g. iPhoneOS16.5)
- `ldid` for ad-hoc signing

## Build

```sh
cd TrollShot
make clean package
```

For a release build:

```sh
make clean package FINALPACKAGE=1
```

The output is a `.deb` under `packages/`. You can extract the `.app` from it and repack as a `.ipa` for TrollStore, or install via a bootstrap tool.

## Repack as IPA for TrollStore

```sh
mkdir -p Payload
cp -r packages/com.example.trollshot_*.deb_work/.theos/_ /
# or extract the .app from the deb and place it in Payload/TrollShot.app
zip -r TrollShot.ipa Payload
```

Then install `TrollShot.ipa` with TrollStore.

## Usage

1. Open the TrollShot app on the device.
2. Note the URL shown on the black screen.
3. From another device on the same network, open `http://<device-ip>:8080/screenshot`.

## Limitations

- The app must remain in the foreground (or be allowed background execution) for the HTTP server to keep responding. iOS will suspend background apps after a short time.
- For a persistent background service, you would need to split the capture server into a root daemon like TrollVNC does (`trollvncserver` + `trollvncmanager`).
- Private entitlements are required; this will not work on stock, non-jailbroken devices. It is intended for TrollStore or jailbroken environments.

## Files

- `ScreenCapturer.{h,mm}` — screen capture via private APIs
- `HTTPScreenshotServer.{h,mm}` — tiny HTTP server
- `AppDelegate.{h,m}` / `main.m` — iOS app bootstrap
- `include-spi/` — minimal private framework declarations
- `TrollShot.entitlements` — required entitlements
- `Makefile` — Theos build config
