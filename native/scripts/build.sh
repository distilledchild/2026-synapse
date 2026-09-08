#!/bin/bash
set -euo pipefail
source_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${1:-$source_root/build}"
mkdir -p "$build_root/module-cache" "$build_root/Synapse.app/Contents/MacOS" "$build_root/Synapse.app/Contents/Resources"
swiftc -module-cache-path "$build_root/module-cache" -target arm64-apple-macosx13.0 -O -parse-as-library \
    "$source_root/Sources/MessageStore.swift" "$source_root/Sources/SendTypes.swift" "$source_root/Sources/PhotoFile.swift" "$source_root/Sources/ContactNames.swift" \
    "$source_root/Sources/MessageSender.swift" "$source_root/Sources/MessageNames.swift" "$source_root/Sources/InboxModel.swift" "$source_root/Sources/MessageComposer.swift" "$source_root/Sources/AttachmentPreview.swift" "$source_root/Sources/OutgoingPhotoPreview.swift" "$source_root/Sources/InboxStatusBar.swift" "$source_root/Sources/SynapseApp.swift" \
    -o "$build_root/Synapse.app/Contents/MacOS/Synapse" -framework SwiftUI -framework AppKit -framework Contacts -lsqlite3
cp "$source_root/Resources/Info.plist" "$build_root/Synapse.app/Contents/Info.plist"
swiftc -module-cache-path "$build_root/module-cache" -target arm64-apple-macosx13.0 -O -parse-as-library \
    "$source_root/Sources/SendTypes.swift" "$source_root/Sources/PhotoFile.swift" "$source_root/Sources/SenderHelper.swift" \
    -o "$build_root/Synapse.app/Contents/MacOS/SynapseSender" -framework Foundation
swiftc -module-cache-path "$build_root/module-cache" -target arm64-apple-macosx13.0 -O -parse-as-library \
    "$source_root/Sources/MessageNames.swift" "$source_root/Sources/NameHelper.swift" \
    -o "$build_root/Synapse.app/Contents/MacOS/SynapseNames" -framework Foundation
swift -module-cache-path "$build_root/module-cache" "$source_root/scripts/make-icon.swift" "$build_root/AppIcon.iconset" "$build_root/Synapse.app/Contents/Resources/AppIcon.icns"
codesign --force --sign - --timestamp=none --options runtime --entitlements "$source_root/Resources/SynapseSender.entitlements" "$build_root/Synapse.app/Contents/MacOS/SynapseSender"
codesign --force --sign - --timestamp=none --options runtime --entitlements "$source_root/Resources/SynapseSender.entitlements" "$build_root/Synapse.app/Contents/MacOS/SynapseNames"
codesign --force --sign - --timestamp=none --options runtime --entitlements "$source_root/Resources/Synapse.entitlements" "$build_root/Synapse.app"
codesign --verify --deep --strict "$build_root/Synapse.app"
