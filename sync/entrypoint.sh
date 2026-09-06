#!/bin/bash
set -euo pipefail

INTERVAL="${SYNC_INTERVAL:-300}"

echo "[entrypoint] naive-sync loop starting, interval=${INTERVAL}s"

while true; do
    /app/sync-naive.sh || echo "[entrypoint] sync-naive.sh exited with code $?"
    sleep "$INTERVAL"
done
