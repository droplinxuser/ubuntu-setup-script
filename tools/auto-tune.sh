#!/usr/bin/env bash
# Hardware-aware auto-tune entry point.
#
# Runs setup.sh --auto-tune, which tunes the OS (CPU governor, PAM limits,
# kernel/network/memory sysctls) and every installed service (Angie, PHP-FPM,
# MariaDB, Valkey/Redis, Elasticsearch) from the current CPU, RAM and disk.
# Safe to run repeatedly: services restart only when their configuration
# actually changed, and a full backup/report is written under /var/backups
# and /var/log.
#
# Usage: sudo bash tools/auto-tune.sh [--dry-run]
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SETUP="${SCRIPT_DIR}/../setup.sh"

[[ -f $SETUP ]] || { printf 'setup.sh not found at %s\n' "$SETUP" >&2; exit 1; }

exec bash "$SETUP" --auto-tune "$@"
