# TrackAir

**Turn your iPhone or iPad into a trackpad and keyboard for your Mac.**
Full-screen, all the macOS gestures, end-to-end encrypted, no accounts, no
servers, nothing leaves your Wi-Fi.

Italiano: [README.it.md](README.it.md)

- Tap to click, two-finger secondary click, two-finger scroll with real
  trackpad momentum (Safari swipe-back and rubber-banding work), pinch to
  zoom, three-finger drag, hold-to-drag, four-finger swipes for Spaces and
  Mission Control, four-finger pinch for the Apps view.
- Keyboard: type any text on the Mac, with a bar of Cmd / Ctrl / Alt / Shift /
  Esc / Tab / arrows for shortcuts. Hardware keyboards work too.
- iPad: full screen or a resizable pad.
- Pairing by pointing the camera at a glowing code shown on the Mac (or a
  6-digit PIN). After that every packet is encrypted and authenticated
  (X25519, HKDF, ChaCha20-Poly1305, replay protection). See `SECURITY.md`.
- Mac app in the menu bar: paired devices, launch at login, Accessibility
  helper.
- **Web version**: the Mac app also serves the trackpad as a web page for any
  phone or tablet, no App Store, no expiry.
- English and Italian.

## What you need

- A Mac with macOS 13 or later.
- An iPhone or iPad with iOS/iPadOS 17 or later, on the same Wi-Fi as the Mac.
- To build and install the native iOS app: **Xcode 15 or later** and an Apple
  ID added in Xcode → Settings → Accounts. A free account is enough, with two
  limits: the app on the device expires after **7 days** and must be
  reinstalled, and you can have at most 3 such apps. See
  [AutoSign](https://github.com/mvennarini/AutoSign) to automate the renewal,
  or use the web version, which never expires.
- [xcodegen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.

## Setup on the Mac

1. Clone this repository and build the Mac app:
   ```
   git clone https://github.com/mvennarini/TrackAir.git
   cd TrackAir
   ./build.sh mac
   open build/TrackAir.app
   ```
   The script signs the app with your own Apple Development certificate
   (created by Xcode when you added your Apple ID), so the Accessibility
   permission survives rebuilds.
2. A hand icon appears in the menu bar. macOS asks for the **Accessibility**
   permission: open System Settings → Privacy & Security → Accessibility and
   enable TrackAir. This is the only way an app can move the pointer.
3. Optional: menu → **Launch at login**.

## Setup on the iPhone or iPad (native app)

1. Connect the device with a cable, unlock it, and trust the computer if asked.
   On the device enable **Developer Mode** (Settings → Privacy & Security →
   Developer Mode; iOS asks for a restart).
2. Build and install:
   ```
   ./build.sh ios
   ```
   The first time Xcode registers the device and creates a provisioning
   profile with your Apple ID; this can take a minute.
3. If iOS says "Untrusted Developer" when you open the app: Settings →
   General → VPN & Device Management → your Apple ID → Trust.
4. Open TrackAir. Allow **Local Network** access (needed to find the Mac) and,
   when asked, the **camera** (only to read the pairing code).
5. The Mac shows a glowing code inside a floating sphere. Point the camera at
   it. Done: the device is paired for good. You can also type the PIN shown
   under the code.
6. The screen turns into the trackpad. Top corner: a green dot (connected), a
   keyboard button and the settings gear.

To renew after 7 days: plug the device in (or have it reachable over Wi-Fi
with "Connect via network" enabled in Xcode → Devices) and run
`./build.sh ios` again. Or let [AutoSign](https://github.com/mvennarini/AutoSign)
do it for you.

## Setup with the web version (any phone, no expiry)

1. With the Mac app running, open the menu and choose **Copy web address**
   (something like `http://my-mac.local:7788`).
2. On the phone or tablet, open that address in Safari (or any browser) while
   on the same Wi-Fi.
3. Share → **Add to Home Screen**. Open it from the Home Screen: it runs full
   screen.
4. Enter the PIN shown on the Mac. Same gestures, keyboard and encryption as
   the native app. Differences: no haptic feedback, and pairing is by PIN only
   (browsers only allow the camera on HTTPS).

## Gestures

| Gesture | Effect |
|---|---|
| one finger | move the pointer (macOS-like acceleration) |
| tap / double tap | click / double click |
| hold one finger still | click-and-hold, then drag with any finger |
| two fingers | scroll with momentum |
| two-finger tap | secondary click |
| pinch | zoom (Cmd + / Cmd −) |
| three fingers | drag |
| four fingers left / right | previous / next Space |
| four fingers up / down | Mission Control / close it |
| four-finger pinch | Apps view (pinch in to open, spread to close) |
| keyboard button | type on the Mac; bar with modifiers, Esc, Tab, arrows |

Defaults mirror the Trackpad settings of the Mac the app was developed on;
every gesture is a switch in the settings.

## Build details

`project.yml` is the source of truth; `TrackAir.xcodeproj` is generated by
xcodegen. `build.sh` detects your team and certificate from the keychain; you
can override them with the `TEAM`, `MAC_SIGN_ID` and `BUNDLE_IOS` environment
variables. Change `BUNDLE_IOS` (and the bundle identifiers in `project.yml`)
if you publish your own build.

```
./build.sh test     # unit tests for the secure layer
./build.sh mac      # build/TrackAir.app
./build.sh ios      # build and install on the connected iPhone/iPad
./build.sh release  # Developer ID signed and notarized Mac build (paid Apple account)
```

The Mac app renders the pairing sphere with Metal; the shader is compiled at
launch from `Mac/SphereShaders.metal.txt`, so no Metal toolchain is needed to
build.

## Project layout

```
Shared/Protocol.swift        messages (9-byte UDP payloads)
Shared/Secure.swift          framing, pairing, encryption, replay protection, peer store
Shared/Localizable.xcstrings English + Italian
Mac/                         menu bar app: Server (UDP), WebServer (HTTP + WebSocket),
                             MouseController (CGEvent), PairingController, SphereMetalView
Mac/trackpad.html            the web client
iOS/                         UIKit lifecycle + SwiftUI: Client, TrackpadView (gesture engine),
                             KeyboardBridge, ScannerView, ContentView
Tests/                       XCTest for the secure layer
Tools/makeicon.swift         the app icon, drawn with CoreGraphics
```

## Privacy and security

No data collection of any kind; see `PRIVACY.md`. Threat model and protocol
in `SECURITY.md`. Please report security issues privately.

## Credits

Designed and built by Michele Vennarini with the support of AI tools.

## License

MIT. Third-party notices in `THIRD_PARTY.md`.
