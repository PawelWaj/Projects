#!/usr/bin/env bash
# Message counts of the queues of one flow on the local broker (the evidence of an L2 run), or drain a queue.
#   bash <kit>/broker/queues.sh <module>                     counts: subscription queue + every output queue
#   bash <kit>/broker/queues.sh <module> --drain <queue>     consume everything on that queue (AMQP), then the counts
set -u
. "$(dirname "$0")/lib.sh"
M=${1:?usage: queues.sh <module> [--drain <queue>]}
need_module "$M"; need_home; need_password
if [ "${2:-}" = --drain ] && [ -n "${3:-}" ]; then
  artemis_client consumer --protocol AMQP --destination "queue://$3" --message-count 100000 --receive-timeout 1500 --break-on-null 2>&1 \
    | grep -E "Consumed:" | tail -1 | sed "s/^/$3: /"
fi
stat=$(artemis_client queue stat --maxRows 500 --maxColumnSize -1 2>&1)
echo "$stat" | grep -E '^\|NAME' | head -1
while IFS=$'\t' read -r name address routing filter; do
  [ "$routing" = address ] && continue
  echo "$stat" | grep -E "^\|$name *\|" || echo "|$name| (missing: artemis_prepare.sh $M)"
done < <("$PY" "$KIT/broker/plan_queues.py" "$M" --tsv | tr -d '\r')
echo "columns: CONSUMER COUNT (the route is attached) · MESSAGE COUNT (waiting now) · MESSAGES ADDED (ever) · MESSAGES ACKED (taken)"
