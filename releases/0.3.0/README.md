# Synapse 0.3.0 — Telegram local alpha

Messages, Telegram, and All inboxes. Personal Telegram account authentication,
existing names/profile photos, paged main-list cloud history, live updates,
loaded-message search, text and one-photo sending. Apple Messages functionality
is preserved.

- [Install DMG](Synapse-0.3.0-arm64.dmg)
- [Source ZIP](Synapse-0.3.0-source.zip)
- [Install and usage guide](Synapse-local-test-guide.md)
- [SHA-256 checksums](Synapse-0.3.0-SHA256.txt)

Apple Silicon, macOS 26+. Ad-hoc signed, not notarized. Runtime dependencies and
licenses are bundled. No API credentials, session data, or message databases are
included. Enter API credentials in the app; they are stored in macOS Keychain.

313 automated checks passed, including 59 Telegram checks and 15 sensitive-file
guard checks. The bundled TDLib C interface starts/closes without an account.
Synthetic UI inspection covers names, Korean text, history, search, unified
navigation, and credential fields. Real Telegram account login and end-to-end
message delivery still require user validation.
