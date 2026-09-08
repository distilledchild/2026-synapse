#!/bin/bash
set -euo pipefail
source_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${1:-$source_root/build}"
mkdir -p "$build_root/module-cache"
swiftc -suppress-warnings -module-cache-path "$build_root/module-cache" -target arm64-apple-macosx13.0 \
    -parse-as-library "$source_root/Sources/MessageStore.swift" "$source_root/Tests/StoreTests.swift" \
    -o "$build_root/store-tests" -lsqlite3
"$build_root/store-tests"
swiftc -module-cache-path "$build_root/module-cache" -target arm64-apple-macosx13.0 \
    -parse-as-library "$source_root/Sources/MessageStore.swift" "$source_root/Sources/SendTypes.swift" "$source_root/Sources/PhotoFile.swift" "$source_root/Sources/ContactNames.swift" \
    "$source_root/Sources/MessageSender.swift" "$source_root/Sources/MessageNames.swift" "$source_root/Sources/InboxModel.swift" "$source_root/Tests/SendTests.swift" \
    -o "$build_root/send-tests" -framework SwiftUI -framework AppKit -framework Contacts -lsqlite3
"$build_root/send-tests"
swiftc -module-cache-path "$build_root/module-cache" -target arm64-apple-macosx13.0 \
    -parse-as-library "$source_root/Sources/MessageStore.swift" "$source_root/Sources/SendTypes.swift" "$source_root/Sources/PhotoFile.swift" "$source_root/Sources/ContactNames.swift" \
    "$source_root/Sources/MessageSender.swift" "$source_root/Sources/MessageNames.swift" "$source_root/Sources/InboxModel.swift" "$source_root/Tests/ContactTests.swift" \
    -o "$build_root/contact-tests" -framework SwiftUI -framework AppKit -framework Contacts -lsqlite3
"$build_root/contact-tests"
swiftc -module-cache-path "$build_root/module-cache" -target arm64-apple-macosx13.0 -parse-as-library \
    "$source_root/Sources/MessageNames.swift" "$source_root/Sources/NameHelper.swift" \
    -o "$build_root/name-helper-tests" -framework Foundation
swiftc -module-cache-path "$build_root/module-cache" -target arm64-apple-macosx13.0 -parse-as-library \
    "$source_root/Sources/MessageStore.swift" "$source_root/Sources/SendTypes.swift" "$source_root/Sources/PhotoFile.swift" \
    "$source_root/Sources/ContactNames.swift" "$source_root/Sources/MessageSender.swift" "$source_root/Sources/MessageNames.swift" \
    "$source_root/Sources/InboxModel.swift" "$source_root/Tests/MessageNameTests.swift" \
    -o "$build_root/message-name-tests" -framework SwiftUI -framework AppKit -framework Contacts -lsqlite3
"$build_root/message-name-tests" "$build_root/name-helper-tests"
swiftc -module-cache-path "$build_root/module-cache" -target arm64-apple-macosx13.0 -parse-as-library \
    "$source_root/Sources/MessageStore.swift" "$source_root/Sources/SendTypes.swift" "$source_root/Sources/PhotoFile.swift" \
    "$source_root/Sources/ContactNames.swift" "$source_root/Sources/MessageSender.swift" "$source_root/Sources/MessageNames.swift" \
    "$source_root/Sources/InboxModel.swift" "$source_root/Tests/HistoryTests.swift" \
    -o "$build_root/history-tests" -framework SwiftUI -framework AppKit -framework Contacts -lsqlite3
"$build_root/history-tests"
swiftc -module-cache-path "$build_root/module-cache" -target arm64-apple-macosx13.0 -parse-as-library \
    "$source_root/Sources/InboxStatusBar.swift" "$source_root/Tests/LayoutTests.swift" \
    -o "$build_root/layout-tests" -framework SwiftUI -framework AppKit
"$build_root/layout-tests"
swiftc -module-cache-path "$build_root/module-cache" -target arm64-apple-macosx13.0 \
    -parse-as-library "$source_root/Sources/MessageStore.swift" "$source_root/Sources/MessageComposer.swift" \
    "$source_root/Sources/AttachmentPreview.swift" "$source_root/Tests/ComposerImageTests.swift" \
    -o "$build_root/composer-image-tests" -framework SwiftUI -framework AppKit -lsqlite3
"$build_root/composer-image-tests"
swiftc -module-cache-path "$build_root/module-cache" -target arm64-apple-macosx13.0 -parse-as-library \
    "$source_root/Sources/SendTypes.swift" "$source_root/Sources/PhotoFile.swift" "$source_root/Sources/SenderHelper.swift" \
    -o "$build_root/photo-helper-tests" -framework Foundation
swiftc -module-cache-path "$build_root/module-cache" -target arm64-apple-macosx13.0 -parse-as-library \
    "$source_root/Sources/MessageStore.swift" "$source_root/Sources/SendTypes.swift" "$source_root/Sources/PhotoFile.swift" \
    "$source_root/Sources/ContactNames.swift" "$source_root/Sources/MessageSender.swift" "$source_root/Sources/MessageNames.swift" "$source_root/Sources/InboxModel.swift" \
    "$source_root/Tests/PhotoTests.swift" -o "$build_root/photo-tests" -framework SwiftUI -framework AppKit -framework Contacts -lsqlite3
"$build_root/photo-tests" "$build_root/photo-helper-tests"
