#!/bin/bash
set -euo pipefail
source_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${1:-$source_root/build}"
bash "$source_root/scripts/build.sh" "$build_root"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_root/Resources/Info.plist")
stage="$(mktemp -d "$build_root/package.XXXXXX")"
cp -R "$build_root/Synapse.app" "$stage/Synapse.app"
cp "$source_root/INSTALL.md" "$stage/READ-ME.md"
ln -s /Applications "$stage/Applications"
hdiutil makehybrid -hfs -hfs-volume-name "Synapse $version" -o "$stage-volume.dmg" "$stage"
hdiutil convert "$stage-volume.dmg" -format UDZO -ov -o "$build_root/Synapse-$version-arm64.dmg"
hdiutil verify "$build_root/Synapse-$version-arm64.dmg"
