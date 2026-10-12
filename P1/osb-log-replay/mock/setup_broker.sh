#!/usr/bin/env bash
# Creates the input address, the filtered subscription queue and the output queues in the mock broker,
# from replay-config.json. Run after `docker compose up -d artemis` and whenever the config changes.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] && set -a && . ./.env && set +a
python3 ../tools/broker_setup_commands.py ../replay-config.json | while IFS= read -r cmd; do
  echo "+ ${cmd%%--user*}"
  docker compose exec -T -e ARTEMIS_USER="${ARTEMIS_USER:-artemis}" -e ARTEMIS_PASSWORD="$ARTEMIS_PASSWORD" artemis sh -c "$cmd" \
    || echo "  (already exists or failed: check the output above)"
done
