#!/bin/zsh
# PrinterKit – avvio su macOS (doppio clic dal Finder sulla chiavetta).
KIT="${0:A:h}"
# File copiati da una chiavetta FAT/exFAT possono perdere il permesso di esecuzione o avere la quarantena.
xattr -dr com.apple.quarantine "$KIT/macos" 2>/dev/null
chmod +x "$KIT/macos/printerkit.sh" 2>/dev/null
exec /bin/zsh "$KIT/macos/printerkit.sh" "$@"
