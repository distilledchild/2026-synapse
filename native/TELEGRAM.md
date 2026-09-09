# Telegram integration — 0.3.3 local alpha

Synapse uses TDLib's personal-account client API. The initial scope is one
Telegram account, cloud chats, existing names and profile photos, paged history,
live updates, text and one-photo sending, and searching loaded conversations.
The All inbox combines connected Apple Messages conversations with Telegram.
Search keeps the whole loaded conversation visible. Messages UI and sending
continue to use the existing Apple Messages adapter.

## Connect

1. Open Telegram in Synapse's platform selector.
2. Enter the API ID and API hash from https://my.telegram.org/apps, then Continue.
3. Choose **Log in with QR code**. In Telegram on your phone, open Settings →
   Devices → Link Desktop Device and scan the QR. Enter your two-step verification
   password in Synapse if requested.
   Phone-number login is also available. Its code screen shows the actual delivery
   method and permits resending only when Telegram offers it and its timeout has
   elapsed. Switch directly to QR if a phone code does not arrive.
4. Choose a chat. Use Load older messages and Load more chats as needed.

You can reconnect with saved credentials. Disconnect closes the local client and
clears in-memory messages and drafts; it preserves the encrypted session cache.
It does not log out or revoke a Telegram session. Revoke a session from the
official Telegram app's Settings → Devices when needed.

QR login follows TDLib's [requestQrCodeAuthentication](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1request_qr_code_authentication.html)
and [other-device confirmation updates](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1authorization_state_wait_other_device_confirmation.html).
Resending follows the [server-provided delivery method and deadline](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1resend_authentication_code.html).

## Private data boundaries

- API credentials and a random 256-bit database encryption key are stored using
  macOS Keychain, on this device only, with synchronization disabled.
- Login codes and passwords are submitted directly to TDLib and are not saved by
  Synapse. TDLib stores its authorized session in its encrypted local database.
- QR login links are short-lived secrets rendered locally with Core Image. The
  current token stays in memory, updates with TDLib, and is cleared on leaving the
  QR state. No external QR service, image file, clipboard, or log is used. The Git
  guard also rejects login token literals.
- Session and chat databases are in `~/Library/Application Support/Synapse/Telegram/database`.
  Downloaded media is in the sibling `files` directory. These paths are outside
  the repository, owner-only, and excluded from backups. TDLib encrypts its
  databases; downloaded media files are ordinary local files, protected by the
  directory permissions and the Mac's disk security.
- TDLib logging is disabled before creating a client. Requests, server payloads,
  phone numbers, credentials, and message text are never logged by the adapter.
  UI errors use fixed allowlisted descriptions.
- Outgoing photos are validated, copied into the private media directory, and
  checked before submission. Successful or definitively failed uploads remove
  the temporary copy. Uncertain/pending uploads retain their copy so TDLib can
  finish; Synapse never submits an automatic duplicate request.
- The repository excludes environment secrets, sessions, databases, credentials,
  diagnostic build output, and clipboard screenshots. Local pre-commit/pre-push
  hooks inspect staged/pushed content and source ZIPs. Enable them in each clone:

  ```sh
  git config --local core.hooksPath .githooks
  python3 scripts/check-sensitive-files.py --working
  ```

The scanner is an additional check, not a substitute for reviewing the exact
files being committed. Release packages contain executable code, libraries,
licenses, and documentation only. No API credentials are embedded in the app.

## Behavior and current limits

- Enter sends; Shift+Enter adds a line. Input-method composition is preserved.
- One JPG/PNG photo up to 20 MB can be sent. Text remains in the composer after a
  photo send. Existing text and photo permissions are respected. Sending does
  not opt into paid messages or broadcasts.
- A pending send stays pending until TDLib confirms it. Unknown outcomes keep
  the draft and block duplicate submission until the user checks Telegram.
- Viewed messages are marked read when visible in the active app. Typing and
  online state are forwarded. Incoming edits/deletions update loaded content;
  expired messages are removed. These are not ghost-mode views.
- Main-list chats are loaded incrementally. Archived folders, secret chats,
  calls, reactions, outgoing edits/deletions, and multiple Telegram accounts are
  not implemented. Unsupported content links back to the official Telegram web
  app. Registration, premium-purchase requirements, and passkeys must be handled
  in the official app.
- Link thumbnails start loading even when no image is cached and clear the old
  image when their file changes. Link cards preserve Telegram’s `skip_confirmation`
  flag: hidden destinations show the exact URL before opening. Cancel opens
  nothing; only the displayed, approved URL is opened. Direct opening remains
  available when Telegram explicitly permits it. Cards only open absolute HTTP(S)
  URLs; display labels and application/file schemes are not navigation targets.
- Search covers loaded messages. Media previews use Telegram's own files; web
  URLs in messages are not fetched by Synapse to generate previews.
- Synapse is an independent client, not an official Telegram application.

## Build and validation

This local binary requires Apple Silicon and macOS 26 or later because its
bundled TDLib/OpenSSL libraries target macOS 26. Apple Messages 0.2.10 remains
available for earlier macOS versions. No Homebrew installation is required to
run the packaged app.

TDLib: **1.8.67**, source revision
`d1085f9cebc5a62379991ae1652673954f229c1f` (Boost Software License 1.0).
The bundle also includes OpenSSL 3 libraries and their license. The build copies
and signs dependencies, rewrites non-system library paths, and verifies that the
result has no dependency on Homebrew paths. Ad-hoc apps have no Developer ID team
for macOS library validation, so this local build uses the app-scoped library
validation entitlement. Before loading, Synapse verifies its full app signature
and every bundled library against the signed SHA-256 manifest. It never searches
for libraries in writable external directories.

To reproduce the pinned runtime:

```sh
brew install cmake gperf openssl@3
bash native/scripts/install-telegram-runtime.sh
SYNAPSE_TDLIB_PREFIX="$PWD/native/build/tdlib-runtime" bash native/scripts/build.sh
bash native/scripts/test.sh
SYNAPSE_TDLIB_PREFIX="$PWD/native/build/tdlib-runtime" bash native/scripts/package.sh
```

An existing Homebrew TDLib installation at the exact pinned revision is also
accepted. Production bundling fails on other revisions rather than silently
using a different API schema.

Tests use an in-memory secrets provider and a synthetic Telegram transport. They
cover credential boundaries, authorization phases, history and update ordering,
permissions, duplicate/unknown sends, early send confirmations, photo integrity,
and stale events after disconnect. A separate check loads the bundled TDLib and
exercises its actual C JSON interface without API credentials or account login.
Real-account login and end-to-end message delivery require user validation.
