# Third-party code

- **noble-curves, noble-ciphers, noble-hashes** by Paul Miller (MIT), bundled
  minified inside `Mac/trackpad.html` to give the web client the same
  cryptography as the native app (X25519, HKDF, HMAC, ChaCha20-Poly1305).
  https://github.com/paulmillr/noble-curves
- QR code matrix generation on the Mac uses Apple's CoreImage; the web page
  has no other dependencies.
