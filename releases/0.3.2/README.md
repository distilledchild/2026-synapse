# Synapse 0.3.2 — Telegram profile photos & link previews

Profile photos (avatars) are now rendered properly using downloaded local cache.
Rich link preview cards (`TelegramLinkPreviewCard`) display webpage thumbnail,
site name, title, description, and direct browser navigation.

- [Install DMG](Synapse-0.3.2-arm64.dmg)
- [Source ZIP](Synapse-0.3.2-source.zip)
- [Install and usage guide](Synapse-local-test-guide.md)
- [SHA-256 checksums](Synapse-0.3.2-SHA256.txt)

Apple Silicon, macOS 26+. Ad-hoc signed, not notarized. Runtime dependencies and
licenses are bundled. API credentials remain in Keychain. Login QR tokens are
rendered locally, stay in memory, and are excluded from logs and files.
No credentials, session data, message databases, or real login QR images are
included in this release.

336 automated checks passed: 239 existing, 81 Telegram, and 16 sensitive-file
guard checks.
