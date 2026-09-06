# Security model

TrackAir lets a phone control a computer, so the transport is designed so that
only devices you paired can do it, and nobody on the network can replay or
forge input.

## Pairing (once per device)

1. The Mac shows a random 6-digit PIN (valid 2 minutes, 3 attempts, then a
   30-second lockout with a fresh PIN).
2. The device generates an ephemeral Curve25519 key pair and sends its public
   key with an HMAC-SHA256 computed with a key derived from the PIN and the
   device ID.
3. The Mac verifies the HMAC, generates its own key pair, answers with its
   public key and an HMAC in the same way.
4. Both sides compute the X25519 shared secret and derive two 256-bit keys
   with HKDF-SHA256 (one per direction, salted with both IDs). The keys are
   stored with restricted permissions (file protection on iOS, mode 0600 in
   Application Support on macOS).

A passive attacker who records the exchange learns nothing useful: the PIN
only authenticates the public keys, the shared secret comes from X25519. An
active attacker would have to guess the PIN online within 3 attempts.

## Session

Every datagram after pairing is `[T][2][1] + senderID + ChaCha20-Poly1305 box`.
The nonce is a random 32-bit session ID plus a 64-bit counter. The receiver
rejects any packet whose counter is not greater than the last accepted one
in the same session, which defeats replay. The sender ID is bound to the
ciphertext as associated data. Unknown or undecryptable packets are ignored;
the Mac answers only with a "pairing needed" frame.

## What is not covered

- Someone who already controls your Mac session or your unlocked phone.
- Denial of service on the local network (UDP flooding).
- The PIN is shown on the Mac screen: anyone who can see the screen during
  the 2-minute window can pair a device. Keep the window closed otherwise.

Reports: use GitHub's private vulnerability reporting on the repository, or open an issue without details and ask for a private channel.
