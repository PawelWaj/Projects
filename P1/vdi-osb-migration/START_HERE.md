# Start here: Splunk CSV + OSB project -> tests + Camel K route, tested locally (JBang + Artemis) -> integration.yaml

One page for a fresh (or reset) VDI. Everything runs in Git Bash on the VDI; nothing unmasked leaves it.
The older guides (RUNBOOK.md, DOMAIN_RUN.md, REVIEW_RUNBOOK.md, pi/VDI_RUNBOOK.md) describe the pieces in detail.

```
OSB project ──► 1 research (pi) ──► research pack (shareable after the check)
Splunk CSV ──► 2 task1: mask + test cases per scenario
           ──► 3 route + tests      scripts path (no model, JMS flows)      -> delivery/<app>/<project>/
                                    skills path  (pi writes it, HTTP flows)  -> modules/<project>/<proxy>/
           ──► 4 local tests: JBang/Maven tests, gates, mutation check, local Artemis run
           ──► 5 camel-k/integration.yaml (one file) ──► handed over for Argo CD (Dev)
```

The approach (decided 2026-10-25): the skills path, `GEN=skills` (the default). The agent scans the OSB source and the
Splunk cases and writes the route into a work module; tests, gates and the mutation check stay script-generated and
frozen. The scripts path (`GEN=scripts`, no model, JMS flows only) remains a fallback and a comparison (`GEN=both`).

## 1. Fresh VDI setup (once after every reset)

Needed on the machine: Git Bash, JDK 21, Maven 3.9 with the client `settings.xml` (Nexus), Python 3.10+, the OSB
application folder. For research and the skills path also Node.js 22 with pi. Nothing else: Artemis, the JBang jar and
Camel JBang come through Maven (Nexus), no internet and no manual download.

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

# 4. check (0 failures; pi warnings are fine when you only run task1 + scripts path + local tests)
bash $KIT/pi/preflight.sh

# 5. local test environment, once after a reset (~1 min, everything through Maven/Nexus): Artemis distribution,
#    broker instance + start, the JBang jar + a `jbang` launcher in ~/bin, Camel/JUnit fetched by a smoke test
export ARTEMIS_PASSWORD='<choose one>'          # per session, never in a file
bash $KIT/pi/env_setup.sh install && . ./.osb-kit.env
#    expected at the end: "Result: N ok, 0 failed". Any time later, read-only: bash $KIT/pi/env_setup.sh check
#    (PI_PING=1 also asks the model for OK through pi)
```

Every later session (VDI not reset): `cd /e/Pawel/work && . ./.osb-kit.env && export ARTEMIS_PASSWORD=...` then
`bash $KIT/pi/vdi_session.sh start` (starts the broker if it is down). Windows opens the broker in its own window:
closing that window stops it.

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
bash $KIT/pi/vdi_session.sh flows '<a-prj>'           # GEN=skills by default; GEN=both adds the no-model comparison
rm "$EXPORT"                                     # raw export gone once task1 wrote task1/events.masked.csv
```

`flows` runs: research (pi, skips flows already PASS) -> task1 -> route + tests -> local tests -> Artemis run ->
review archive -> Camel K files. Rerun after a fix (research unchanged): `bash $KIT/pi/vdi_session.sh review '<a-prj>'`.
HTTP flows, after the gates are green: `bash $KIT/pi/vdi_session.sh smoke '<a-prj>'` starts the route on Camel Main, sends every
case over HTTP against a stub backend and compares the replies (`smoke_http.py`). JMS flows: `broker/run_local.sh <module>`.

What to check (counts only when you send screenshots):

| Where | Good result |
|---|---|
| `task1/SUMMARY.md` | `OK` per flow, no `CHECK` lines (CHECK = wrong scenario field in research.json) |
| scripts path, log step 5 | `N tests, 0 failed` |
| scripts path, log step 6 | `Sending to <queue>` and `+N` per queue (local Artemis, not the E2E broker) |
| skills path | `ok K2..K12`, `K8_tests_green` ok (K1 stays FAIL in POC mode: approval is a person's step) |
| last line of GEN=both | `scripts: N tests, 0 failed   skills: tests green, gates failed: K1` |
| mutation check | `mutations caught x/x` (run by `vdi_session.sh flows` for green modules, or `mutate_route.py`) |
| HTTP smoke (`vdi_session.sh smoke '<a-prj>'`) | `PASS <case>` per case and `PASS error case`, last line `smoke: N cases, 0 failed, error case ok` (the route really running, called over HTTP, backend played by a stub; `SMOKE.txt` in the module) |

## 4. integration.yaml for Argo CD (handed to the colleague who deploys)

Deploy only after the local tests are green. Each flow gets `camel-k/integration.yaml` (Kamelets, ConfigMaps with
route/Java/properties/OSB files, the Integration; one file), `DEPLOY.md` (the Secrets it needs) and `CHECK.json`
(ready, open values). Dev gets it through Argo CD: hand over `integration.yaml` + `DEPLOY.md`; the colleague puts the
file into the GitOps repository and creates the Secrets. Values per environment never go in this repository; write
them in when generating:

```
export CAMELK_NAMESPACE=<dev namespace>
export CAMELK_BROKER_URL=<broker of the namespace>     # scripts path: tcp://<artemis-service>:61616 (core protocol);
                                                       # skills path:  amqp://<artemis-service>:5672 or failover:(...)
export CAMELK_ENV_FILE=/e/Pawel/work/dev.env           # KEY=VALUE for {{env:X}} of HTTP routes (hosts, ids), local file
bash $KIT/pi/vdi_session.sh deploy '<a-prj>'           # regenerates; "ready": true = no CHANGE-ME left
#   without oc on the VDI it only writes the files; with oc login it also runs a server dry run and checks the Secrets
#   hand over: <folder>/camel-k/integration.yaml + DEPLOY.md (scripts path: delivery/<app>/<project>/camel-k/)
```

`APPLY=1` applies directly with `oc` (only where the platform allows it; with Argo CD the GitOps repository is the
way in, and a direct apply would be reverted by Argo CD).

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
| `ROUTE DID NOT START`, `TODO(flow-card) destination of <bs>` | research.json has no queue for that business service (UNKNOWN): fix `outputs[].destination`, rerun `flows` (`review` reuses the old module) |
| `broker did not answer within 60s` | port 61616/5672/8161 taken (another broker), or wrong JAVA_HOME: `artemis_setup.sh status`, log in `$ARTEMIS_BROKER/log/` |
| `NOT READY` on deploy | `CHANGE-ME` values listed in `camel-k/DEPLOY.md`: set `CAMELK_BROKER_URL` / `CAMELK_ENV_FILE` and rerun deploy |

Data rules: masked data, OSB source and review packs stay on the VDI; only research packs that pass the check may
leave it. MASK_KEY and passwords are typed per session. Screenshots show names and counts, never message values.
