# The run as a decision procedure

`pipeline_state.py` encodes this order. Read it to understand what a stage is, what proves it, and what its good
output looks like; never to skip ahead.

| # | Stage (state item) | Proven by | Command the state proposes | Good output |
|---|---|---|---|---|
| 1 | env: settings | `./.osb-kit.env` + `APP` with `*-prj` folders | HUMAN: `vdi_session.sh setup <osb-app-folder>` | `Result: … 0 failures` (preflight) |
| 2 | env: maven-settings | `~/.m2/settings.xml` (Nexus mirror) | HUMAN: runbook step 2 | `curl … -> 200` |
| 3 | env: artemis, jbang, camel-smoke | distribution + instance + broker answering on 8161; `jbang` on PATH; `.env-smoke/SMOKE.ts` | `env_setup.sh install` (needs `ARTEMIS_PASSWORD` exported) | `Result: N ok, 0 failed` |
| 4 | research | `research/<p>/<x>/SHARE_CHECK.json` pass | `vdi_session.sh flows '<p>'` (pi) | `PASS` in `domain/STATUS.md`; may loop once on `dims:` |
| 5 | task1 | `task1/flows/<slug>/fixtures/parity` | same `flows` (needs `EXPORT` + `MASK_KEY`; without an export: synthetic cases) | `OK: n scenarios, m test cases`, `residue findings 0`, no `CHECK` |
| 6 | module (tests, route, gates) | `modules/<p>/<x>/GATES.json` | same `flows`; later `vdi_session.sh review '<p>'` | `verify: PASS after N call(s)`, `ok K2 … ok K12`, `Tests run: N, Failures: 0` |
| 7 | card | `FLOW_CARD.md`: `Status: approved`, `Approver:`, no `- [ ]` left | HUMAN: `card_answers.py <module>` (recommended answer per question, Enter accepts) | `approved: yes`, `CARD_ANSWERS.json` |
| 8 | K1 refreeze | `GATES.json` newer than the card, K1 ok | `vdi_session.sh review '<p>'` | `=== refreeze …`, `ok K1_card_approved` (green module: no pi call) |
| 9 | mutations | `MUTATION.json` killed == total (or a survivor accepted in writing: `MUTATION_ACCEPTED.md`), newer than `src/main` | `mutate_route.py <module> --mvn "mvn -B -q $MVN_ARGS"` | `mutations caught x/x` |
| 10 | local-run | HTTP: `SMOKE.json` ok; JMS: `target/e2e-result.json` ok | `vdi_session.sh smoke '<p>'` or `broker/e2e_local.sh <module>` | `smoke: N cases, 0 failed, error case ok` / `RESULT: every output queue got what the tests expect` |
| 11 | review-pack | `review/<p>-<x>.tgz` newer than the module | `make_review_pack.sh <p> <x>` | the `.tgz` path |
| 12 | local-acceptance | `LOCAL_ACCEPTANCE.json` PASS, newer than `src/main` and the card | `local_acceptance.sh '<p>'` (card, tests+gates incl. K1, mutations, the route on Camel JBang as on Camel K: HTTP smoke / JMS on the local Artemis, integration.yaml checked, review pack) | `LOCAL ACCEPTANCE: PASS <p>/<x>` |
| 13 | deploy-file | `camel-k/CHECK.json` ready | HUMAN: Dev values + namespace (+ `CAMELK_SECRET_KEYS` for credentials), then `vdi_session.sh deploy '<p>'` | `"ready": true` |
| 14 | handover | — | DONE | `integration.yaml` + `DEPLOY.md` to the colleague (GitOps repo, Argo CD) |

Stages 4–6 are one command (`flows`) because research, task1 and the build share the model session settings; the
state re-proposes `flows` until the module exists, then `review` for anything that is red. A red gate other than K1
after `review` means the implementer could not pass the frozen tests: the state proposes `review` again once; the
agent stops after two identical results and reports the gate names (a person reads `verify_module.py` output).

Why the order matters: tests are generated from research + cases before the route (6), so a wrong card (7) means
wrong tests; mutations (9) only mean something on a green module; the smoke run (10) found a defect the mocked tests
cannot see (`bridgeEndpoint`); the review package (11) must contain the final module; the deploy file (12) carries the
properties file, so it is generated last.

Three human gates, in words the person can act on:

1. **Card approval** — `python $KIT/skills/osb-camelk-route/scripts/card_answers.py <module>`: each open question with
   its evidence and a recommended answer in brackets; Enter accepts, typing replaces, `s` skips. The card is approved
   (Status/Approver/Date) only when no question is left. The operator never runs it with `--defaults`.
2. **MASK_KEY** — when a Splunk export is given, the data owner's key is typed in the shell before the run.
3. **Dev values** — the keys listed under `open` in `camel-k/CHECK.json` (hosts, ids) into a local file, plus the
   namespace, exported before `deploy`.
