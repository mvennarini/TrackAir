# Changelog

## 1.1.0 – 2026-09-07
- Bluetooth LE link (Mac peripheral, iOS central) with Automatic / Wi-Fi /
  Bluetooth setting and automatic fallback; the same pairing works on both.
- Smoother pointer: 240 Hz filtered motion with sub-pixel precision on the
  Mac, coalesced touch samples and time-based acceleration on iOS, gap
  bridging by velocity extrapolation, Wi-Fi keep-awake, Wi-Fi QoS.
- Keyboard: type on the Mac with a modifier bar; hardware keyboards.
- Four-finger pinch opens and closes the Apps view.
- Web version served by the Mac app (HTTP + WebSocket), never expires.
- Pairing by pointing the camera at a glowing code in a Metal-rendered
  sphere, PIN as fallback.
- Retry and re-pair buttons when the Mac does not answer; the Mac listens only
  on its primary interface.

## 1.0.0 – 2026-09-06
- Full-screen trackpad for iPhone and iPad (landscape), resizable on iPad.
- Gestures mirroring macOS: tap to click, two-finger secondary click,
  two-finger scroll with momentum (trackpad phases, works with Safari
  swipe-back), pinch to zoom, three-finger drag, hold-to-drag, four-finger
  Spaces and Mission Control.
- Secure pairing with PIN, end-to-end encrypted and replay-protected transport.
- Mac menu bar app: paired devices, launch at login, Accessibility helper.
- English and Italian.
