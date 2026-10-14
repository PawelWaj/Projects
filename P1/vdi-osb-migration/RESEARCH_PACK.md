# Research pack — when the OSB source cannot leave the VDI

The OSB source stays on the VDI. pi reads it and writes a **research pack**: facts plus answers to a fixed
questionnaire, in plain language and mapping tables, with **no code, no hosts, no credentials, no data**. A check
blocks the pack until it is clean. Only the pack is sent out; from it the Camel K route and the tests are designed.

## Once
- pi installed and logged in (`P1/skills/osb-camel-agent-kit/pi/PI_SETUP.md`), Python 3, Git Bash.
- Kit: the repo (`~/Projects/P1/skills/osb-camel-agent-kit`) or bootstrap script `8_install_skill_osb_research.sh`.
- Check: `bash $P1/skills/osb-camel-agent-kit/pi/preflight.sh` shows `skill osb-research discoverable`.

## Per proxy (pilot: maintain-adjustment)
1. OSB project on the VDI, the version deployed in E2E: `~/work/osb-migration/osb-src/beneficiary-engagement-change-prj/`
   (plus shared projects it references).
2. Run, in `~/work/osb-migration`:
   ```
   bash $P1/skills/osb-camel-agent-kit/pi/run_research.sh osb-src/beneficiary-engagement-change-prj maintain-adjustment /e/Pawel/maintain-adjustment/task1
   ```
   The third argument (task 1 output) lets the pack map the 15 Splunk scenarios to branches.
   - `== 1 facts`: script, sanitised inventory of the proxy (`facts.json`, `SOURCES.txt`).
   - `== 2 questionnaire`: pi answers Q1–Q12 (entry, format, flow, branches, scenario mapping, outputs, transforms,
     backends, errors, logging, dependencies, open questions) into `RESEARCH.md` + `research.json`.
   - `== 3 share check`: must end with `PASS`. On `FAIL` the flagged lines are listed (rule + 3-character preview):
     rerun step 2, or fix the lines by hand (describe instead of quoting, remove the value), then
     `python $P1/skills/osb-camel-agent-kit/skills/osb-research/scripts/research_check.py research/maintain-adjustment`.
3. Read `RESEARCH.md` yourself once: is anything in it that must not leave? The check is a safety net, not a licence.
4. Send: `research/maintain-adjustment/RESEARCH.md`, `research.json`, `facts.json`, `SHARE_CHECK.json`.
   Never send `SOURCES.txt`-listed files, `research/*.agent-logs` (they may quote source) or anything from `osb-src/`.

## What comes back
From the pack: the flow card, the Camel K YAML route (replacing the stand-in block in `P1/pilot/maintain-adjustment`),
the selector/branch/error tests, and the WireMock/Artemis mocks. Expected output bodies are still computed ON the VDI
by running the original XQuery on the masked inputs (task 2, `golden_runner.py`); they never leave the VDI either.

## Interactive alternative
In pi: `/osb-research osb-src/beneficiary-engagement-change-prj maintain-adjustment /e/Pawel/maintain-adjustment/task1`
