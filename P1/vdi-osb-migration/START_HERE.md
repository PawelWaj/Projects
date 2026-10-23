# Start here: Splunk CSV + OSB project -> tests + Camel K route -> integration.yaml on Dev

One page for a fresh (or reset) VDI. Everything runs in Git Bash on the VDI; nothing unmasked leaves it.
The older guides (RUNBOOK.md, DOMAIN_RUN.md, REVIEW_RUNBOOK.md, pi/VDI_RUNBOOK.md) describe the pieces in detail.

```
OSB project ──► 1 research (pi) ──► research pack (shareable after the check)
Splunk CSV ──► 2 task1: mask + test cases per scenario
           ──► 3 route + tests      scripts path (no model, JMS flows)      -> delivery/<app>/<project>/
                                    skills path  (pi writes it, HTTP flows)  -> modules/<project>/<proxy>/
           ──► 4 local tests: JBang/Maven tests, gates, mutation check, local Artemis run
           ──► 5 camel-k/integration.yaml (one file) ──► oc apply to the Dev namespace
```

Which path for which flow: a JMS/topic flow -> scripts path first (`GEN=scripts`, minutes, no model). An HTTP
request/reply flow -> skills path (`GEN=skills`). Not sure -> `GEN=both` and compare the last line.

## 1. Fresh VDI setup (once after every reset)

Needed on the machine: Git Bash, JDK 21, Maven 3.9 with the client `settings.xml` (Nexus), Python 3.10+, Node.js 22
with pi, the Artemis distribution zip (local broker test), `oc` (deploy), the OSB application folder.

```
# 1. kit: download the ZIP of the repository (P1/), unzip, e.g. to /e/Pawel/Projects-main
export KIT=/e/Pawel/Projects-main/P1/skills/osb-camel-agent-kit
cd "$KIT/../../" && git log --oneline -1 2>/dev/null || ls -l --time-style=+%F "$KIT/pi/run_domain.sh"   # which kit

# 2. workspace + settings (writes .osb-kit.env with the paths it finds; check JAVA_HOME, Maven, ARTEMIS_HOME in it)
mkdir -p /e/Pawel/work && cd /e/Pawel/work
bash $KIT/pi/vdi_session.sh setup <osb-application-folder>

# 3. pi: install from the internal npm mirror if it is gone, then point it at the model platform
npm install -g --ignore-scripts @earendil-works/pi-coding-agent && pi --version
#    ~/.pi/agent/models.json: provider baseUrl + model id (see pi/VDI_RUNBOOK.md section 3); then
export OSB_PI_MODEL=<model id>  PACER=0  PI_OFFLINE=1  PI_TELEMETRY=0
echo 'Reply OK' | pi --print --no-session --model "$OSB_PI_MODEL" < /dev/null      # must answer OK

# 4. check + local broker
bash $KIT/pi/preflight.sh                       # fix every FAIL
bash $KIT/pi/vdi_session.sh start               # asks the Artemis password (not stored), starts the local broker
```

`PACER=0` = pi talks to the model directly. Long model calls are stopped after `PI_TIMEOUT` seconds (default 1800);
for a slow model use `export PI_TIMEOUT=3600`. `PI_THINKING=low` makes the model write less (faster); go back to
`medium` if the routes come out weak.

## 2. Splunk export (per project, stays on the VDI)

Counts first (no values), then the export of the request lines with a body. Index and sourcetype are the client's
values (never in the repository; keep them in `.osb-kit.env` as `SPLUNK_INDEX`, `SPLUNK_SOURCETYPE`):

```
index=<index> sourcetype="<sourcetype>" earliest=-90d@d ("<a-prj>" OR "<b-prj>") ("::{" OR "::<")
| dedup _raw | sort 0 _time | head 20000 | table _time _raw
```

Save as CSV to `/e/Pawel/work/<name>.csv`. The raw CSV is deleted after task1 (step 3 masks it).

## 3. One project, from CSV to tested route

```
cd /e/Pawel/work && . ./.osb-kit.env
export EXPORT=/e/Pawel/work/<name>.csv
export MASK_KEY=<from the data owner, typed now, never in a file>
GEN=both bash $KIT/pi/vdi_session.sh flows '<a-prj>'
rm "$EXPORT"                                     # raw export gone once task1 wrote task1/events.masked.csv
```

`flows` runs: research (pi, skips flows already PASS) -> task1 -> route + tests -> local tests -> Artemis run ->
review archive -> Camel K files. Rerun after a fix without the model: `GEN=scripts bash $KIT/pi/vdi_session.sh review '<a-prj>'`.

What to check (counts only when you send screenshots):

| Where | Good result |
|---|---|
| `task1/SUMMARY.md` | `OK` per flow, no `CHECK` lines (CHECK = wrong scenario field in research.json) |
| scripts path, log step 5 | `N tests, 0 failed` |
| scripts path, log step 6 | `Sending to <queue>` and `+N` per queue (local Artemis, not the E2E broker) |
| skills path | `ok K2..K12`, `K8_tests_green` ok (K1 stays FAIL in POC mode: approval is a person's step) |
| last line of GEN=both | `scripts: N tests, 0 failed   skills: tests green, gates failed: K1` |
| mutation check | `mutations caught x/x` (run by `vdi_session.sh flows` for green modules, or `mutate_route.py`) |

## 4. Deploy to Dev with integration.yaml

Each flow gets `camel-k/integration.yaml` (Kamelets, ConfigMaps with route/Java/properties/OSB files, the
Integration; one file), `DEPLOY.md` and `CHECK.json` (ready, open values). Values per environment never go in the
repository:

```
export CAMELK_NAMESPACE=<dev namespace>
export CAMELK_BROKER_URL=<broker of the namespace>     # scripts path: tcp://<artemis-service>:61616 (core protocol);
                                                       # skills path:  amqp://<artemis-service>:5672 or failover:(...)
export CAMELK_ENV_FILE=/e/Pawel/work/dev.env           # KEY=VALUE for {{env:X}} of HTTP routes (hosts, ids), local file
oc login <dev cluster>
bash $KIT/pi/vdi_session.sh deploy '<a-prj>'           # regenerates, checks open values + Secrets, oc dry run
#   create the Secrets DEPLOY.md lists (broker user/password, API keys), typed in the window
APPLY=1 bash $KIT/pi/vdi_session.sh deploy '<a-prj>'   # apply; then: oc get integration -n $CAMELK_NAMESPACE -w
```

`DEPLOY_FROM=skills` deploys the pi-written module even when a scripts delivery exists. Remove a flow:
`oc delete -n $CAMELK_NAMESPACE -f <folder>/camel-k/integration.yaml`.

Open points to confirm with the platform team before the first apply: Camel K is an operator (the program rule says
no application operators: confirm it is allowed for Dev); the broker port per path (the scripts-path kamelets speak
the Artemis core protocol on 61616, the Artemis LLD names AMQP 5672); Secrets by hand today vs Vault later.

## 5. When something is red

| Symptom | Cause, fix |
|---|---|
| research loops on `dims:` | a scenario field written with words; it fixes itself (research_check), else edit `scenario_dims` to `header.<name>` or `//<name>` |
| `ROUTE DID NOT START`, `Cannot resolve dependencies` | `camel run` cannot reach Nexus: `MVN_ARGS="-s <settings.xml>"` in `.osb-kit.env` |
| `ROUTE DID NOT START`, `No endpoint ... TODO(flow-card)` | the proxy's entry (queue/topic) is unknown in research.json: fix `entry` and rerun `review` |
| `pi did not finish within ...s` | slow model or a hanging call: `PI_TIMEOUT=3600`, check the model platform |
| skills path stays red after 3 rounds | `python $KIT/skills/osb-camelk-route/scripts/verify_module.py modules/<p>/<x>` shows the first errors; tests are frozen, only route/beans/stubs change |
| `NOT READY` on deploy | `CHANGE-ME` values listed in `camel-k/DEPLOY.md`: set `CAMELK_BROKER_URL` / `CAMELK_ENV_FILE` and rerun deploy |

Data rules: masked data, OSB source and review packs stay on the VDI; only research packs that pass the check may
leave it. MASK_KEY and passwords are typed per session. Screenshots show names and counts, never message values.
