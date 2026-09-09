#!/bin/bash
set -euo pipefail
source_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${1:-$source_root/build}"
mkdir -p "$build_root/module-cache"
swiftc -module-cache-path "$build_root/module-cache" -target arm64-apple-macosx13.0 -parse-as-library \
    "$source_root/Sources/SendTypes.swift" "$source_root/Sources/PhotoFile.swift" \
    "$source_root/Sources/Telegram/TelegramSecurity.swift" "$source_root/Sources/Telegram/TelegramClient.swift" \
    "$source_root/Sources/Telegram/TelegramTypes.swift" "$source_root/Sources/Telegram/TelegramAuthentication.swift" "$source_root/Sources/Telegram/TelegramModel.swift" \
    "$source_root/Tests/Telegram/TelegramTests.swift" -o "$build_root/telegram-tests" \
    -framework SwiftUI -framework AppKit -framework Security
library="$build_root/Synapse.app/Contents/Frameworks/libtdjson.dylib"
if [[ -f "$library" ]]; then
    "$build_root/telegram-tests" "$library"
else
    "$build_root/telegram-tests"
fi
python3 "$source_root/../scripts/test-sensitive-files.py"
