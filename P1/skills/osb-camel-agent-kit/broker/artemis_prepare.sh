#!/usr/bin/env bash
# Creates on the LOCAL broker what one flow needs (plan_queues.py from <module>/env/local.properties): the subscription
# queue with the OSB selector as its filter, one anycast queue per output. Existing objects are left alone.
#   bash <kit>/broker/artemis_prepare.sh <module> [--dry-run]       (--dry-run prints the CLI commands only)
# On the platform these objects come from the Git register (never auto-create); here the script stands in for it.
set -u
. "$(dirname "$0")/lib.sh"
M=${1:?usage: artemis_prepare.sh <module> [--dry-run]}; DRY=${2:-}
need_module "$M"; need_home; [ "$DRY" = --dry-run ] || need_password
while IFS=$'\t' read -r name address routing filter; do
  case $routing in
    address)   args=(address create --name "$address" --multicast);;
    multicast) args=(queue create --name "$name" --address "$address" --multicast --durable --preserve-on-no-consumers --auto-create-address --silent)
               [ -n "$filter" ] && args+=(--filter "$filter");;
    anycast)   args=(queue create --name "$name" --address "$address" --anycast --durable --auto-create-address --silent);;
    *) continue;;
  esac
  if [ "$DRY" = --dry-run ]; then printf 'artemis'; printf ' %q' "${args[@]}"; echo; continue; fi
  if [ "$routing" != address ] && artemis_client queue stat --queueName "$name" 2>/dev/null | grep -q "^|$name *|"; then
    echo "exists: $name on $address"; continue
  fi
  artemis_client "${args[@]}" 2>&1 | grep -iE "created|already|exist|error|exception" | head -1 | sed "s/^/$name: /"
done < <("$PY" "$KIT/broker/plan_queues.py" "$M" --tsv)
[ "$DRY" = --dry-run ] || bash "$KIT/broker/queues.sh" "$M"
