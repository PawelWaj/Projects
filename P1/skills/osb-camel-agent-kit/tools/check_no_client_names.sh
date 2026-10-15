#!/usr/bin/env bash
# Blocks a commit that adds client-specific names. The deny list is NOT in the repo: one extended regex per line in
# ${OSB_KIT_DENYLIST:-~/.osb-kit-denylist} (client name, system names, internal queue/project names, Splunk names).
# Usage: tools/check_no_client_names.sh [--staged | <file>...]     Install as hook: tools/check_no_client_names.sh --install
set -u
DENY=${OSB_KIT_DENYLIST:-$HOME/.osb-kit-denylist}
if [ "${1:-}" = "--install" ]; then
  top=$(git rev-parse --show-toplevel) || exit 1
  printf '#!/usr/bin/env bash\nexec "%s" --staged\n' "$(cd "$(dirname "$0")" && pwd)/check_no_client_names.sh" > "$top/.git/hooks/pre-commit"
  chmod +x "$top/.git/hooks/pre-commit"; echo "pre-commit hook installed in $top"; exit 0
fi
[ -s "$DENY" ] || { echo "no deny list at $DENY (one regex per line): nothing checked"; exit 0; }
pattern=$(grep -v '^\s*#' "$DENY" | grep -v '^\s*$' | paste -sd'|' -)
if [ "${1:-}" = "--staged" ] || [ $# -eq 0 ]; then
  hits=$(git diff --cached -U0 | grep '^+' | grep -v '^+++' | grep -inE "$pattern" | cut -c1-160)
else
  hits=$(grep -inE "$pattern" "$@" | cut -c1-160)
fi
if [ -n "$hits" ]; then
  echo "BLOCKED: client-specific names found (deny list $DENY):"; echo "$hits" | head -20
  echo "use placeholders or the local ~/.osb-kit.env instead"; exit 1
fi
echo "ok: no client-specific names"
