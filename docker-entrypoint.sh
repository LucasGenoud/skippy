#!/bin/sh
set -eu

# Named volumes created by older images contain root-owned databases/uploads.
# Repair their ownership before dropping privileges so upgrades remain safe.
if [ "$(id -u)" = "0" ]; then
    chown -R sticky-notes:sticky-notes /data
    chown sticky-notes:sticky-notes /backups
    exec gosu sticky-notes "$@"
fi

exec "$@"
