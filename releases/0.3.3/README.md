# Synapse 0.3.3 — Link preview fixes

Link preview thumbnails now load from their initially empty state and clear stale
images when the file changes. Preview cards honor Telegram's URL confirmation
metadata, show the exact destination before opening when required, and only open
the URL the user approved. Cancel opens nothing.

- [Install DMG](Synapse-0.3.3-arm64.dmg)
- [Source ZIP](Synapse-0.3.3-source.zip)
- [Install and usage guide](Synapse-local-test-guide.md)
- [SHA-256 checksums](Synapse-0.3.3-SHA256.txt)

Apple Silicon, macOS 26+. Build 16, ad-hoc signed, not notarized. Runtime
dependencies and licenses are bundled. No API credentials, session data, message
databases, or real login QR images are included. Credentials remain in Keychain.

344 automated checks passed: 239 existing, 89 Telegram, 16 sensitive-file checks.
Synthetic UI inspection verified thumbnail rendering, uncached replacement and
restoration, cancellation, confirmation, and direct-open requests. UI tests
capture navigation requests without opening a browser. Real Telegram message
delivery remains outside these checks.
