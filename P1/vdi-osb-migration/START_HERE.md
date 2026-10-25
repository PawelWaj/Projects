# Start here: a reset VDI to one OSB flow on Camel K with tests, a review package and integration.yaml

Runbook for the client VDI (Git Bash on Windows; macOS/Linux work the same). Approach: the agentic (skills) path — the
pi agent on the VDI scans the OSB source and the masked Splunk cases and writes the route; tests, gates and the
mutation check are script-generated and frozen. Values in `<angle brackets>` are client values: they live in
`.osb-kit.env` on the VDI and in the client's own notes, never in this repository. Detail guides: `pi/VDI_RUNBOOK.md`
(pi setup), `broker/LOCAL_BROKER_TEST.md`, `REVIEW_RUNBOOK.md`.

```
OSB source ──► 1 research (pi) ───────────► research pack
Splunk CSV ──► 2 task1: mask, cases per scenario
           ──► 3 pi writes the route ──► 4 frozen tests, 12 gates, mutation check  (Maven on the VDI only)
           ──► 5 card approved by a person ──► review package (stays on the VDI)
           ──► 6 camel-k/integration.yaml + DEPLOY.md ──► colleague ──► GitOps repo ──► Argo CD ──► Dev
```

## One command: the operator agent runs steps 3–10 (kit ≥ `osb_agent`)

Splunk is the input, everything else is driven by `pi/osb_agent.sh`: a pi operator (skill `osb-migration-run`, role
`agents/operator-osb.md`) reads the state of the run (`pipeline_state.py`: what the scripts left behind), executes the
one next kit command, reads the state again, and stops where a person must act. Steps 1–2 (kit, Nexus settings) stay
manual; so does `vdi_session.sh setup` once per machine.

```
cd /e/Pawel/work && . ./.osb-kit.env
export OSB_PI_MODEL=<model id> PACER=0 ARTEMIS_PASSWORD='<password>'
export EXPORT=/e/Pawel/work/<name>.csv MASK_KEY='<from the data owner>'     # only when there is a Splunk export
bash $KIT/pi/osb_agent.sh '<a-prj>'                                         # --no-pi: same loop without the operator model
```

It ends with one of: `HUMAN: …` (exit 3: do what it says, run the same line again), `DONE: …` (exit 0: hand over
`camel-k/integration.yaml` + `DEPLOY.md`), or a stop after two rounds without progress (exit 1: the state table and the
last log lines say which stage). The three human gates: **card approval** (`FLOW_CARD.md`: tick the open questions,
`Status: approved`, `Approver`, `Date`), **MASK_KEY** (asked in the shell when `EXPORT` is set), **Dev values**
(the keys `CHECK.json` lists, into a local file, plus `CAMELK_NAMESPACE`/`CAMELK_ENV_FILE`); a fourth, rare one: a
**surviving mutation** (fix the missing scenario, or accept it in writing in `MUTATION_ACCEPTED.md`). Logs:
`domain/agent-run.log` (every command), `domain/agent-<date>.out` (what the operator said). The state alone, any time:
`python $KIT/skills/osb-migration-run/scripts/pipeline_state.py '<a-prj>'`.

## 0. What a green flow proves, and what it does not

Proves: the route behaves like OSB on every logged scenario (parity tests from real Splunk cases), the error path
answers with OSB's status and headers, the backend is called as OSB calls it (mutations: a dropped backend call, a
changed error status and a changed HTTP method are each caught), the route is complete (no `TODO(flow-card)` left),
no infrastructure values in code, the tests were not touched by the agent.
Does not prove, until 6.6 has run: a live HTTP request through the running route (the smoke run; it found a defect
the mocked tests cannot see, see 6.6). Never proves: byte-for-byte equality with OSB's real reply where Splunk did
not log it, behaviour on the cluster. Say "on a local run on the VDI
with mocked backends", never "validated on Dev".

## 1. Machine prerequisites (ask IT if missing; nothing else is downloaded from the internet)

| Item | Check | Seen on a VDI |
|---|---|---|
| Git Bash | `bash --version` | yes |
| JDK 21 | `java -version` (ignore the `Picked up JAVA_TOOL_OPTIONS` line) | 21 |
| Maven 3.9 | `mvn -v` | 3.9.9 |
| Python 3.10+ | `python --version` | under `C:\Program Files` (a path with a space: fixed in kit `601cd79`) |
| Node 22 + pi | `pi --version` | pi present, not on the Git Bash PATH (step 4) |
| Model endpoint | pi `models.json` provider | `<model id>` on the model platform; no rate limit → `PACER=0`, else the pacer (`PACER=1`) |
| Nexus | `curl` test in step 3 | `http://<nexus-host>:<port>/repository/maven-public/` **client** |
| OSB application source | folder with `*-prj` subfolders | path per project, e.g. `/e/Pawel/osb/<application>` |
| Splunk access | E2E index, request lines | index and sourcetype in `.osb-kit.env` (`SPLUNK_INDEX`, `SPLUNK_SOURCETYPE`) |

## 2. Kit (2 min)

Download the ZIP of `PawelWaj/Projects` (branch main, commit `4371011` or later), unzip next to the workspace. Kit and
workspace are separate folders: the kit is replaced as a whole on every update, the workspace keeps the client data.

```
cd /e/Pawel && unzip -q ~/Downloads/Projects-main.zip          # or: tar -xf
export KIT=/e/Pawel/Projects-main/P1/skills/osb-camel-agent-kit
ls $KIT/pi/env_setup.sh $KIT/pi/vdi_session.sh                  # both exist
ls $KIT/skills/osb-camelk-route/scripts/smoke_http.py             # exists = kit >= 4371011
```

## 3. Maven settings with the client Nexus (2 min)

Maven, JBang and `camel run` all resolve through `~/.m2/settings.xml`; JBang reads only that file. Mirror without
credentials, no `<localRepository>` line (the default `~/.m2/repository` is fine):

```
mkdir -p ~/.m2 && cat > ~/.m2/settings.xml <<'XML'
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0 https://maven.apache.org/xsd/settings-1.0.0.xsd">
    <interactiveMode>false</interactiveMode>
    <mirrors>
        <mirror><id>nexus</id><mirrorOf>*,!<extra-releases-repo></mirrorOf>
            <url>http://<nexus-host>:<port>/repository/maven-public/</url></mirror>
    </mirrors>
    <profiles>
        <profile><id>nexus</id>
            <repositories>
                <repository><id>nexus</id><url>http://<nexus-host>:<port>/repository/maven-public/</url>
                    <releases><enabled>true</enabled></releases><snapshots><enabled>true</enabled></snapshots></repository>
                <repository><id><extra-releases-repo></id><url>http://<nexus-host>:<port>/repository/<extra-releases-repo>/</url>
                    <releases><enabled>true</enabled></releases><snapshots><enabled>false</enabled></snapshots></repository>
            </repositories>
            <pluginRepositories>
                <pluginRepository><id>nexus</id><url>http://<nexus-host>:<port>/repository/maven-public/</url>
                    <releases><enabled>true</enabled></releases><snapshots><enabled>true</enabled></snapshots></pluginRepository>
            </pluginRepositories>
        </profile>
    </profiles>
    <activeProfiles><activeProfile>nexus</activeProfile></activeProfiles>
</settings>
XML
curl -s -o /dev/null -w '%{http_code}\n' http://<nexus-host>:<port>/repository/maven-public/junit/junit/4.13.2/junit-4.13.2.pom   # 200
```

`000` = no route to the host (name or proxy), `401` = Nexus wants a login (add `<servers>`), `404` = wrong repository path.

## 4. Workspace, settings file, pi on the PATH (5 min)

```
mkdir -p /e/Pawel/work && cd /e/Pawel/work
bash $KIT/pi/vdi_session.sh setup /e/Pawel/osb/<application>    # the folder ABOVE the *-prj folders; writes .osb-kit.env + preflight
#   find it: find /e /c/Users/$USERNAME -maxdepth 5 -type d -name '*-prj' 2>/dev/null | head -3
ls "$APPDATA/npm" | grep -i '^pi'                                 # pi, pi.cmd
echo 'export PATH="$(cygpath -u "$APPDATA")/npm:$PATH"' >> .osb-kit.env
. ./.osb-kit.env
export OSB_PI_MODEL=<model id> PACER=0 PI_TIMEOUT=3600 PI_OFFLINE=1 PI_TELEMETRY=0     # client: model id
echo 'Reply OK' | pi --print --no-session --model "$OSB_PI_MODEL" < /dev/null                      # OK
```

`.osb-kit.env` is local (never in Git) and holds KIT, APP, WS, JAVA_HOME, PATH, MVN_ARGS, ARTEMIS_*. Passwords and
MASK_KEY are never written there: exported per session. If pi is not installed at all: `pi/VDI_RUNBOOK.md` section 3
(npm from the internal mirror, `models.json` with the provider baseUrl and model id).

## 5. Local test environment: Artemis, JBang, Camel (5–10 min, everything through Nexus)

```
cd /e/Pawel/work && . ./.osb-kit.env
bash $KIT/pi/env_setup.sh check                       # read-only: what is there, what is missing, one line each
export ARTEMIS_PASSWORD='<choose one>'                # per session; the instance is created with it
bash $KIT/pi/env_setup.sh install && . ./.osb-kit.env
PI_PING=1 bash $KIT/pi/env_setup.sh check             # Result: N ok, 0 failed  (incl. "model answers")
```

`install` fetches the Artemis distribution through Maven (or reuses an unzipped `apache-artemis-*` next to the
workspace), creates the broker instance and starts it (Windows: its own window, closing it stops the broker), copies the
JBang jar and a `jbang` launcher into `~/bin`, runs a one-test Camel smoke through JBang (fetches Camel 4.18, Saxon,
JUnit once) and warms up Camel JBang for `camel run`. Seen on a VDI: first `check` 8 ok / 7 failed (no settings.xml),
after step 3 and `install` all green.

## 6. One flow, from Splunk to integration.yaml

### 6.1 Splunk (counts first, then the export; stays on the VDI)

R2, counts and structure only (safe to screenshot):

```
index=<index> sourcetype="<sourcetype>" earliest=-90d@d "oracle.osb.logging.pipeline" "<project-prj>"
| rex "Project (?<project>\S+) :: for (?<kind>PS|BS) (?<svc>\S+)"
| eval fmt=case(match(_raw,"::\s*\{"),"json",match(_raw,"::\s*<"),"xml",true(),"-")
| eval day=strftime(_time,"%F")
| rex "(?s)TraceID\s*[-:]\s*\S+\s*::(?<body>.*)$"
| eval h=if(fmt!="-", md5(body), null())
| stats count dc(day) as days dc(h) as distinct by kind, svc, fmt
```

A `PS <proxy> json|xml` row with `distinct` ≥ 30 on ≥ 5 days = READY; ≥ 5 = THIN (synthetic fill for the rest);
everything `-` = no replayable payload, synthetic cases only. Export E1 when there is a payload:

```
index=<index> sourcetype="<sourcetype>" earliest=-90d@d "<project-prj>" ("::{" OR "::<")
| dedup _raw | sort 0 _time | head 20000 | table _time _raw
```

Save as CSV to `/e/Pawel/work/<name>.csv`. If `count` in R2 exceeds 20000, shorten the window instead of cutting.

### 6.2 Research → task1 → route → tests → gates → mutations → manifest (one command)

```
cd /e/Pawel/work && . ./.osb-kit.env
export OSB_PI_MODEL=<model id> PACER=0 PI_TIMEOUT=3600 ARTEMIS_PASSWORD='<password>'
export EXPORT=/e/Pawel/work/<name>.csv MASK_KEY='<from the data owner, typed>'
GEN=skills bash $KIT/pi/vdi_session.sh flows '<project-prj>' 2>&1 | tee run-$(date +%H%M).log
rm "$EXPORT"                                          # raw export gone; task1/events.masked.csv stays
```

What runs: research (pi; skipped when already PASS) → task1 (mask + one case per scenario) → tests and mocks generated
from research and the cases, frozen → pi fills the route in small calls, each followed by `verify_module.py` → Maven
tests + gates K1–K12 → Camel K manifest → mutation check on a green module. No Splunk payload for the project:
`unset EXPORT` and run the same line; missing scenarios get synthetic cases from the message schema.

What to check (counts only when you send it on):

| Where | Good |
|---|---|
| task1 line | `OK: n scenarios, m test cases`, `residue findings 0`, no `CHECK` |
| `== 1 generated tests` | `parity_cases` = real cases, `unmapped_log_scenarios: 0` |
| `== 3 implement` | `verify round N: tests …` then `verify: PASS after N call(s)` (seen: 2 calls) |
| `== 4 verify` | `ok K2 … ok K12`; `K1 FAIL` until the card is approved (6.3) |
| `K8_tests_green` | `failures 0, errors 0` (skipped = cases without a logged reply) |
| `=== mutations` | `mutations caught x/x` |
| `== 5 Camel K deployment` | `"open": [...]` lists the per-environment values still needed (6.5) |
| `task1/events.masked.csv.report.json` | JSON key NAMES not masked by rule: add personal-data fields to `MASK_JSON_KEYS` in `.osb-kit.env`, rerun task1 |

Seen on a VDI, an HTTP request/reply flow: 797 events exported, 178 for the flow, 6 parity cases, 1
scenario; 18 tests 0 failures 2 skipped; K2–K12 ok; mutations 3/3; pi 2 calls.

### 6.3 Card approval (a person, 15 min) and the K1 rerun

`FLOW_CARD.md` is the one-page contract between research and code: entry, branches, scenario mapping, outputs,
backends, transforms, errors, log lines, open questions, `Status/Approver/Date`. Read it against `RESEARCH.md`, tick
every open question (answered, or accepted with a reason), then:

```
M=modules/<project-prj>/<Proxy>
sed -n '/^## 9 Open questions/,$p' $M/FLOW_CARD.md
notepad "$(cygpath -w $M/FLOW_CARD.md)"               # - [ ] -> - [x] … — answered/accepted: <reason>
sed -i 's/^Status:.*/Status: approved/; s/^Approver:.*/Approver: <name> (POC)/; s/^Date:.*/Date: <YYYY-MM-DD>/' $M/FLOW_CARD.md
grep -E '^(Status|Approver|Date):' $M/FLOW_CARD.md; grep -c '^- \[ \]' $M/FLOW_CARD.md     # 0
GEN=skills bash $KIT/pi/vdi_session.sh review '<project-prj>'                              # green module: '=== refreeze', ok K1 (no model call)
```

POC approver: the author. Production mode: the OSB flow owner on the client side approves before implementation
(a prerequisite to put into the change request).

### 6.4 Review package (stays on the VDI)

```
bash $KIT/pi/make_review_pack.sh <project-prj> <Proxy>
ls -la review/<project-prj>-<Proxy>.tgz
```

Contents: research pack, card, the runnable module (`mvn test` works in it), TEST_MATRIX, GATES.json, MUTATION.json,
MIGRATION_NOTES.md. Reviewers: OSB owner → card, TEST_MATRIX, MIGRATION_NOTES; Camel developer → route, beans, stubs,
tests; platform colleague → `camel-k/integration.yaml`, `DEPLOY.md`.

### 6.5 Deployment file for Argo CD

```
cat > /e/Pawel/work/dev.env <<'EOF'                  # per-environment values, local file only
<BACKEND>_HOST=<host on Dev>
<other keys listed under "open" in step 6.2>
EOF
export CAMELK_NAMESPACE=<dev namespace> CAMELK_ENV_FILE=/e/Pawel/work/dev.env     # JMS flows: also CAMELK_BROKER_URL=amqp://<artemis-service>:5672
bash $KIT/pi/vdi_session.sh deploy '<project-prj>'                                 # "ready": true
```

Hand over `modules/<project-prj>/<Proxy>/camel-k/integration.yaml` and `DEPLOY.md`; the colleague puts the file into
the GitOps repository and creates the Secret named in `DEPLOY.md`. A direct `oc apply` would be reverted by Argo CD.
Open with the platform team before the first apply: Camel K is an operator (program rule: no application operators;
Dev exception), Camel K version ≥ 2.3 for Secret-backed env vars, Secrets by hand today vs Vault.

### 6.6 The route really running: HTTP smoke run (HTTP flows) or local broker run (JMS flows)

HTTP flows, after the gates are green: the route is started locally on Camel Main, a stub plays every backend with the
module's stub file, every parity case is POSTed over HTTP and the reply compared JSON-aware, then the stub answers 500
and the route must reply with the OSB error status. Kit ≥ `4371011`.

```
bash $KIT/pi/vdi_session.sh smoke '<project-prj>'        # or: python $KIT/skills/osb-camelk-route/scripts/smoke_http.py modules/<p>/<Proxy>
```

Good: `route up after Ns`, `PASS <case>` per case, `PASS error case: backend 500 -> reply status 500`, last line
`smoke: N cases, 0 failed, error case ok, backend calls: {...}`; `SMOKE.txt` and `SMOKE.json` in the module, route
log in `target/smoke-route.log`. Exit 1 on any failure.

Why it exists: on the lab module the first smoke run failed with `Invalid url: <path>/<path>` — the route
forwarded the entry's `CamelHttpPath` into the backend call. The 18 mocked tests cannot see that (mocks ignore the
URI), gates and mutations were green, and on Dev the route would have failed the same way. Fix: `?bridgeEndpoint=true`
on the backend endpoint; the scaffold writes it since `4371011`. **A module built before that commit (<Flow>
on the VDI) needs one line edited** in `src/main/resources/application.properties`:

```
sed -i -E 's|^(backend\.[a-z0-9]+=https?://[^?]*)$|\1?bridgeEndpoint=true|' modules/<project-prj>/<Proxy>/src/main/resources/application.properties
grep '^backend\.' modules/<project-prj>/<Proxy>/src/main/resources/application.properties     # ends with ?bridgeEndpoint=true
```

then rerun `review` (tests unchanged, K1 stays ok) and `deploy` (the manifest carries the properties file).

JMS flows (no HTTP entry): the local Artemis run instead.

```
bash $KIT/broker/e2e_local.sh modules/<project-prj>/<Proxy>     # queues -> route in the background -> one case per scenario -> queue counts
```

Exit 0 = every output queue received what the tests expect; route log in `target/e2e-route.log`.

## 7. Every later session (VDI not reset)

```
cd /e/Pawel/work && . ./.osb-kit.env
export OSB_PI_MODEL=<model id> PACER=0 PI_TIMEOUT=3600 ARTEMIS_PASSWORD='<password>'
bash $KIT/pi/vdi_session.sh start            # starts the broker if down, prints kit/java/mvn/pi
bash $KIT/pi/env_setup.sh check              # 0 failed
```

## 8. Troubleshooting (all seen on a VDI)

| Symptom | Cause, fix |
|---|---|
| `vdi_session.sh setup` prints `usage: … <osb-application-folder>` | the argument is the folder above the `*-prj` folders |
| `[FAIL] no Maven settings`, `Maven cannot resolve from Nexus` | step 3 |
| `verify round N: … line 55: /c/Program: No such file` | Python under a path with a space; kit < `601cd79`, update the kit |
| `verify round 1..3` identical, 11 `TODO(flow-card)` left, K6 missing stub | pi never ran or failed: `tail modules/<p>/<x>/.agent-logs/implement.err`; test the flags: `echo 'Reply OK' \| pi --print --no-session --thinking low --model "$OSB_PI_MODEL" < /dev/null` |
| `broker refuses the login` | `ARTEMIS_PASSWORD` differs from the one the instance was created with: stop, `mv /e/Pawel/artemis-broker /e/Pawel/artemis-broker.old`, `artemis_setup.sh create && start` |
| `jbang on PATH but does not start` | `jbang --version` prints on stderr; kit ≥ `f5370ae` reads it |
| `[INFO] pi not on PATH` | step 4, `$APPDATA/npm` |
| `pi did not finish within …s` | slow model: `PI_TIMEOUT=3600`; check the model platform |
| `ROUTE DID NOT START` / `Cannot resolve dependencies` | Maven cannot reach Nexus: `MVN_ARGS="-s …"` in `.osb-kit.env`, step 3 |
| `NOT READY` on deploy | values listed in `camel-k/DEPLOY.md`: `dev.env`, rerun deploy |
| `review` after a research change reuses the old module | run `flows`, not `review` |
| K1 `card_changed_after_freeze` | the card was edited after the build: rerun `review` once (6.3) |
| smoke: `FAIL … status 500`, hint `Invalid url … enable the bridgeEndpoint option` | module built before kit `4371011`: the one-line `application.properties` edit in 6.6 |
| smoke: `route did not come up` | port 8089/8099 taken (`--port`, `--stub-port`), or Maven cannot fetch `exec-maven-plugin` / `camel-platform-http-main`: `target/smoke-route.log` |

## 9. Data rules

Masked data, OSB source, XQuery and review packages stay on the VDI; only research packs that pass the share check
leave it. MASK_KEY and passwords are typed per session, never in a file. Raw Splunk exports are deleted after task1.
Screenshots and messages carry names and counts, never values. PROD exports need the client's approval.

## 10. Verified / not verified

Verified 2026-10-25: a reset client VDI through steps 2–6.2 with <model id> (one HTTP flow green, counts above);
`env_setup.sh` from an empty Maven repository and empty home on macOS (40 s, Maven Central); 6.3–6.5 commands come
from the kit scripts and were run on the Mac lab, not yet on this VDI; 6.6 smoke run on the Mac lab module
(1 synthetic case PASS, error case PASS, 2 backend calls; the broken module correctly reported FAIL).
Not verified: 6.6 on Windows (process stop via `taskkill`, Nexus fetch of `exec-maven-plugin`); any apply on a Camel K
cluster; Camel K ≥ 2.3 Secret-env syntax on the client cluster.
