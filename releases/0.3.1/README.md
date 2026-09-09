# Synapse 0.3.1 — Telegram QR login

QR login is available from the phone-number and verification-code screens.
Scan it using Telegram on your phone: Settings → Devices → Link Desktop Device.
The QR rotates automatically and two-step verification remains supported.
Code screens now show the actual delivery method and respect Telegram’s resend
availability and timeout.

- [Install DMG](Synapse-0.3.1-arm64.dmg)
- [Source ZIP](Synapse-0.3.1-source.zip)
- [Install and usage guide](Synapse-local-test-guide.md)
- [SHA-256 checksums](Synapse-0.3.1-SHA256.txt)

Apple Silicon, macOS 26+. Ad-hoc signed, not notarized. Runtime dependencies and
licenses are bundled. API credentials remain in Keychain. Login QR tokens are
rendered locally, stay in memory, and are excluded from logs and files.
No credentials, session data, message databases, or real login QR images are
included in this release.

336 automated checks passed: 239 existing, 81 Telegram, and 16 sensitive-file
guard checks. These include decoding synthetic QR images, token rotation,
resend deadlines, two-step verification, and the bundled TDLib C interface.
Synthetic UI inspection confirmed verification-code to QR navigation and layout.
Real account QR approval and end-to-end delivery still require user validation.
