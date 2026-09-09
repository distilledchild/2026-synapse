# Synapse 0.3.1 — Messages and Telegram

For Apple Silicon Macs running macOS 26 or later. The bundled Telegram runtime requires macOS 26.

## Telegram

Select **Telegram** in the top platform selector. Enter your API ID and API hash,
then choose **Log in with QR code**. On your phone, open Telegram → Settings →
Devices → Link Desktop Device and scan the QR. Complete two-step verification if
requested. Phone/code login remains available. API credentials and the database
key stay in macOS Keychain; codes/passwords are not saved by Synapse. The encrypted
session database and downloaded media are outside the repository in
`~/Library/Application Support/Synapse/Telegram`. Downloaded media files are not
separately encrypted. Logs do not contain Telegram requests or responses.

Use **All** for a combined inbox and search of loaded messages. Telegram supports
main-list cloud chats, names/profile photos, history, live updates, text and one
JPG/PNG photo up to 20 MB. Your text remains after sending a photo. Read/typing
states are forwarded. Secret chats, archived folders, calls, multiple accounts,
and outgoing edits/reactions/deletions are not implemented. Disconnect retains
the encrypted login session; revoke sessions in the official Telegram app when
needed. This is an independent Telegram client.

## Install and connect Apple Messages

1. Open `Synapse-0.3.1-arm64.dmg` and drag Synapse into Applications. Quit the existing app before replacing it.
2. Open Synapse and choose **Connect Messages**.
3. If requested, enable Synapse in **System Settings → Privacy & Security → Full Disk Access**, then quit and reopen the app.
4. Allow Messages Automation access to read participant names and send messages. Contacts access provides a fallback for names.

This is an ad-hoc signed, unnotarized test build. Replacing it may require re-enabling the same app's existing access permissions.

## Conversation history and search

- The inbox starts with the latest 2,000 messages across conversations.
- Opening a conversation loads its latest 1,000 messages. Any additional messages already in the inbox remain visible.
- Choose **Load older messages** to add the preceding 1,000 messages. Continue until **All local history loaded** appears. There is no fixed 2,000-message cap on the conversation.
- **Latest** returns to the newest message. Loading older messages shows the boundary with the previously loaded history so you can continue scrolling backward.
- Search filters the conversation list and highlights matching messages, while keeping the entire loaded conversation visible. **Next match** moves between text matches.
- Search covers loaded messages, including the history you have loaded. It does not search unloaded history or download missing messages from iCloud.
- Five-second inbox refreshes retain older loaded history. Messages and history remain in memory and are cleared on disconnect or app exit.

Only messages present in this Mac's Messages database are available. Reaction and system-event rows are not counted as ordinary message bubbles. Images appear when their local attachments are available.

## Names and language

The interface, help, permission descriptions, errors, sample conversations, and accessibility labels are in English. Actual message text and saved contact names keep their original language.

Names come from Apple Messages, with authorized Contacts access as a fallback. Unsaved numbers remain numbers. Synapse does not provide custom names or modify Contacts. Changing a displayed name never changes the conversation's send target.

## Compose and send

- **Enter** sends; **Shift+Enter** inserts a new line. Enter confirms active input-method composition before sending.
- The composer starts at one line and grows as you type.
- Use **+** to select one JPG, PNG, HEIC, GIF, or WebP photo, up to 20 MB. Check the preview and choose **Send photo**. Typed text remains available to send separately.
- **Sent to Messages** means Messages accepted the request. Check delivery in Apple Messages.
- If a result is unknown, check Messages before manually retrying. Synapse does not retry automatically.
- Drafts exist only in memory and are cleared on disconnect or exit. Imported databases and sample mode never send real messages.

Existing iMessage, SMS, and RCS conversations are supported. New conversations, video and general file sending, reactions, editing, deletion, and a persistent outbox are not implemented. SMS/RCS depend on Messages and the iPhone's forwarding and connection settings.

## Validation

336 automated checks passed: 81 Telegram checks, 16 credential-file guard checks, plus 44 database/body checks, 54 text-send checks, 31 Contacts checks, 29 Messages-name checks, 21 history checks, 21 composer/image checks, 24 photo-send checks, and 15 status-bar layout checks.

History checks cover scoped queries, duplicate/shared joins, exclusive cursors, equal timestamps, concurrent new messages, attachment pages, retries, stale results after disconnect, draft preservation, and retaining older pages during refresh. Original Korean and emoji text remain unchanged.

The installed production app was checked with real local history: conversation loading, repeated older pages through the earliest available messages, full conversation context during search, link thumbnails, English UI, and unchanged contact names/numbers. No real messages or photos were sent during validation.

Telegram tests and UI checks use synthetic data, including QR decoding, token rotation, resend deadlines, two-step verification, and actual bundled TDLib startup/close. Real Telegram login and end-to-end delivery remain unverified. Other macOS versions, every attachment format, and every permission revocation path are also outside these checks.

## Build from source

Unzip `Synapse-0.3.1-source.zip` and run from its root:

```sh
bash native/scripts/test.sh
bash native/scripts/build.sh
bash native/scripts/package.sh
```

See `native/TELEGRAM.md` for the pinned TDLib dependency setup required before building. Build output is in `native/build/`. The source archive excludes local databases, attachments, diagnostic probes, and application backups.

## 0.2.10: Stable composer position during refresh

A refresh spinner previously changed the status bar from 37 pt to 40 pt and back, moving the composer above it by 3 pt. Its 16 × 16 pt slot is now reserved while idle as well as while loading. Status text stays on one line. The bar measures 40 pt in both states across 540, 800, and 1,100 pt widths. Auto-refresh, message history, and composing behavior are unchanged.
