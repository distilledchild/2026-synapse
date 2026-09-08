# Synapse 0.2.10 — Stable status bar during refresh

A small refresh spinner changed the bottom status bar from 37 pt to 40 pt and back. This pushed the composer above it up and down by 3 pt. Its space is now reserved at all times, keeping the status bar at 40 pt. Long status text stays on one line.

- [Install DMG](Synapse-0.2.10-arm64.dmg)
- [Installation and usage](Synapse-local-test-guide.md)
- [Source ZIP](Synapse-0.2.10-source.zip)
- [SHA-256 checksums](Synapse-0.2.10-SHA256.txt)

239 automated checks passed. The production status bar was measured through 40 refresh-state changes at each of three widths, plus long counters, sample mode, and imported-database mode. Every measured height after the fix was 40 pt. Message sending, history, names, and editor behavior are unchanged.

Quit the previous app before replacing it. Apple Silicon, ad-hoc signed, not notarized. Replacing an ad-hoc build may require re-enabling the same app's existing access permissions.
