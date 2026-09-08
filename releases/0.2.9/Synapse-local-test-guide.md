# Synapse 0.2.9 — Local Messages app

For Apple Silicon Macs. Built for macOS 13 or later; tested on macOS 26.6.2.

## Install and connect

1. Open `Synapse-0.2.9-arm64.dmg` and drag Synapse into Applications. Quit the existing app before replacing it.
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

224 automated checks passed: 44 database/body checks, 54 text-send checks, 31 Contacts checks, 29 Messages-name checks, 21 history checks, 21 composer/image checks, and 24 photo-send checks.

History checks cover scoped queries, duplicate/shared joins, exclusive cursors, equal timestamps, concurrent new messages, attachment pages, retries, stale results after disconnect, draft preservation, and retaining older pages during refresh. Original Korean and emoji text remain unchanged.

The installed production app was checked with real local history: conversation loading, repeated older pages through the earliest available messages, full conversation context during search, link thumbnails, English UI, and unchanged contact names/numbers. No real messages or photos were sent during validation.

Other macOS versions, every attachment format, every permission revocation path, and end-to-end transport delivery remain outside these checks.

## Build from source

Unzip `Synapse-0.2.9-source.zip` and run from its root:

```sh
bash native/scripts/test.sh
bash native/scripts/build.sh
bash native/scripts/package.sh
```

Build output is in `native/build/`. The source archive excludes local databases, attachments, diagnostic probes, and application backups.
