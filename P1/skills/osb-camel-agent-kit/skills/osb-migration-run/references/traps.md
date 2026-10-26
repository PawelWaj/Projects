# Known failures and the one fix each allows

Match the error text of the last command (`domain/agent-run.log`, last 40 lines) against the symptom. Apply only the
fix in the row. "HUMAN" = stop and tell the person. Anything not listed: stop and report the lines (names and counts,
no values).

| Symptom (text in the log) | Cause | Fix the agent may apply |
|---|---|---|
| `usage: vdi_session.sh setup <osb-application-folder>` | setup needs the folder above the `*-prj` folders | HUMAN: the person runs setup with that folder |
| `[FAIL] no Maven settings`, `Maven cannot resolve from Nexus`, `Could not transfer artifact`, `Could not resolve dependencies` | no `~/.m2/settings.xml` with the Nexus mirror, or Nexus unreachable | HUMAN: runbook step 2 (settings file + `curl` 200); the agent never edits `~/.m2` |
| `line 55: /c/Program: No such file` | Python under a path with a space; kit older than `601cd79` | HUMAN: update the kit ZIP |
| `verify round 1 … verify round 3` with identical counts, `K2_no_gaps` with `left > 0`, `K6_backend_stubs` missing | the implementer (pi) did not run or failed inside `flows`/`review` | read `modules/<p>/<x>/.agent-logs/implement.err` (last 8 lines, no values) and report it; do not rerun more than once |
| `pi did not finish within …s` | slow model or a hung call | rerun the same command once with `PI_TIMEOUT=7200` prefixed; second time HUMAN |
| `model endpoint still refuses after … retries` (exit 75) | quota or endpoint down | HUMAN: check the model platform; do not retry |
| `broker refuses the login`, `AMQ229031`, `Unable to validate user` | `ARTEMIS_PASSWORD` is not the one the instance was created with | HUMAN: the person recreates the instance (`artemis_setup.sh stop`, move the instance folder, `create`, `start`) |
| `broker did not answer within 60s`, `Address already in use` | port 61616/5672/8161 taken, or wrong JAVA_HOME | run `bash $KIT/broker/artemis_setup.sh status` and report; HUMAN decides |
| `jbang not on PATH` after `env_setup.sh install` | `~/bin` not on the PATH of this shell | `. ./.osb-kit.env` then rerun the state |
| `[INFO] pi not on PATH` | pi installed by npm, not on the Git Bash PATH | HUMAN: `export PATH="$(cygpath -u "$APPDATA")/npm:$PATH"` in `.osb-kit.env` |
| `ROUTE DID NOT START`, `No endpoint … TODO(flow-card)` | research.json has no destination for a business service | HUMAN: fix `outputs[].destination` in research.json, then `flows` |
| research loops on `dims:` | a scenario field written with words | none: `research_check` fixes it on the next round; after two rounds HUMAN |
| `CHECK` lines in `task1/SUMMARY.md` | a scenario field in research.json is not what the logs show | HUMAN: the person fixes `scenario_dims` in research.json; then `flows` |
| `residue findings N` with N > 0 | masking left values that look like identifiers | HUMAN: `MASK_JSON_KEYS` in `.osb-kit.env`, rerun task1 (`flows` with `EXPORT`) |
| `MUTATION SURVIVED`, `mutations caught x/y` with x < y | tests do not catch a change in the route | HUMAN: a missing scenario or case (fix research/task1, rerun `flows`), or the person writes the reason into `<module>/MUTATION_ACCEPTED.md`; never "fix" by editing tests |
| smoke: `FAIL … status 500` with hint `Invalid url … enable the bridgeEndpoint option` | module built with a kit older than `4371011` | `sed -i -E 's\|^(backend\.[a-z0-9]+=https?://[^?]*)$\|\1?bridgeEndpoint=true\|' <module>/src/main/resources/application.properties`, then `review` (the properties file is part of the manifest) |
| smoke: `route did not come up`, `Address already in use` | port 8089/8099 taken, or Maven cannot fetch `exec-maven-plugin` / `camel-platform-http-main` | rerun `smoke_http.py <module> --port 18089 --stub-port 18099` once; else report `target/smoke-route.log` (last 10 lines) |
| `K1_card_approved … card_changed_after_freeze`, or `K1 FAIL` right after the card was approved | the card was edited after the build | the state proposes `review` once: on a green module it prints `=== refreeze` and re-runs the gates without pi (kit ≥ osb_agent) |
| `NOT READY: fill the open values (CHANGE-ME)` on deploy | per-environment values missing | HUMAN: Dev values + `CAMELK_NAMESPACE` + `CAMELK_ENV_FILE`, then `deploy` |
| `no module yet (run flows first)` on smoke/deploy | module not built | the state proposes `flows`; run it |
| `nothing passed the selector` (broker run) | the case headers do not match the JMS selector | HUMAN: compare `headers.json` keys with the selector in research.json (names only) |
| `review reuses the old module` after a research change | `review` never re-scaffolds | run `flows` instead of `review` |
| state says `artemis todo: distribution missing` or `jbang todo: not on PATH` while `env_setup.sh check` is all green | kit < `a423a2f`+: the state did not look next to the workspace for a hand-unzipped Artemis and a Windows Python ignores a `jbang` launcher without extension; update the kit; no edit of `.osb-kit.env` needed |
