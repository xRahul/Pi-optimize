#!/usr/bin/env bash
# ==============================================================================
# RPI5 -> External HDD (EHDD) Unified Backup Utility Launcher
# Host: rahul@192.168.1.24 | Target: /mnt/ehdd/RPI5 (Windows NTFS H:\RPI5)
# ==============================================================================

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
PYTHON_TUI="${SCRIPT_DIR}/ehdd_tui.py"

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

1-Screen App-like Incremental Backup Utility for RPi5 -> External HDD.
Target: /mnt/ehdd/RPI5 (Windows NTFS H:\RPI5)
Hardware: 5000M USB 3.0 SuperSpeed / UAS Optimized

Options:
  -h, --help                 Show this help menu
  -n, --dry-run              Simulate backup without writing data
  -r, --restore              Restore mode: sync from External HDD back to /mnt/usb
  -j, --job <name>           Run a specific dataset:
                               photos       - Camera, Shaadi, WhatsApp, Pictures (~150 GB)
                               immich       - Immich mobile uploads (~15 GB)
                               dad          - Dad personal archive (~23 GB)
                               rahul        - Rahul personal archive (~23 GB)
                               music        - FLAC lossless music archive (~8.7 GB)
                               transmission - Finished torrent downloads (~24 GB)
                               docker       - Docker databases & configs (~1.5 GB)
                               all          - Sync all datasets sequentially (default)
  -a, --add <src> [sub]      Sync any custom directory into /mnt/ehdd/RPI5/[sub]
  -b, --bwlimit <KB/s>       Throttle maximum transfer speed (e.g. 50M)
  -c, --checksum             Deep byte-level checksum verification mode
  --delete                   Mirror mode: delete files from target if deleted on source

Examples:
  $(basename "$0")                          # Full 1-screen live backup of all 7 datasets
  $(basename "$0") --dry-run                # 1-screen preview of transferred files
  $(basename "$0") -j photos                # Sync only Photo & Video archive
  $(basename "$0") -a /mnt/usb/Docs docs    # Sync /mnt/usb/Docs to /mnt/ehdd/RPI5/docs
EOF
    exit 0
fi

chmod +x "$PYTHON_TUI" 2>/dev/null || true
exec python3 "$PYTHON_TUI" "$@"
