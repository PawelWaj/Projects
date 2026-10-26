---
name: osb-migration-run
description: "Operate the whole OSB -> Camel K run for one project on the VDI from a state file, not from memory: run scripts/pipeline_state.py, execute exactly the one next command it prints (environment install, flows, review, mutations, smoke or broker run, review package, local acceptance, deploy file), rerun the state, repeat; stop at the human gates (card approval, MASK_KEY, Dev values) and report. Use when asked to run, continue, finish or automate the migration of an OSB project or flow end to end, or when the user says osb-migration-run or osb_agent."
---

# Run the OSB -> Camel K pipeline from its state

You operate scripts; you do not migrate anything yourself. Research, test generation, the route, the gates, the
mutation check, the smoke run and the Camel K manifest are done by the kit scripts (`vdi_session.sh`,
`env_setup.sh`, `run_domain.sh`, `mutate_route.py`, `smoke_http.py`, `make_review_pack.sh`). Your job is to call them
in the right order, read what they left behind, recognise a known failure, and stop where a person must decide.

Workspace = the current folder (it holds `.osb-kit.env`, `research/`, `task1/`, `modules/`, `review/`, `domain/`).
`$KIT` = the kit folder (exported). Secrets (`ARTEMIS_PASSWORD`, `MASK_KEY`, API keys) are exported by the person
before you start: you never print, echo, write or ask for their values.

## The loop (every turn)

1. `python "$KIT/skills/osb-migration-run/scripts/pipeline_state.py" '<project>'` — one line per item, then exactly
   one of `next:` (a command), `HUMAN:` (a person must act) or `DONE:` (handover).
2. `next:` → run that command, unchanged, through bash (it already appends to `domain/agent-run.log`). Wait for it to
   finish. Do not run anything else in between, do not "improve" the command, do not run `mvn` or `pi` yourself.
3. Rerun step 1. If the state advanced (an item went from todo to done, or `next` changed), continue with step 2.
4. If the same `next` comes back after its command ran: look at the last 40 lines of `domain/agent-run.log`, match
   the error text against `references/traps.md`, and apply only the one fix that row allows, then rerun step 1.
   No row matches, or the same command fails twice → stop and report (step 6).
5. `HUMAN:` or `DONE:` → stop and report (step 6). Never try to pass a human gate yourself.
6. Report, in this order and nothing else: the state table as printed; what ran in this session (commands, one line
   each, with the counts the scripts printed: tests, gates, mutations caught, smoke cases); what the person must do
   next (the `HUMAN:` text verbatim) or `DONE`.

`references/workflow.md` explains what each stage is and what its good output looks like.

## Rules

- One project at a time, the one you were given. Never touch another project's folders.
- Never edit: `FLOW_CARD.md`, `research.json`, `RESEARCH.md`, `FlowParityTest.java`, `FlowErrorTest.java`,
  `flow-test.json`, anything under `src/test/resources/parity`, `GATES.json`, `MUTATION.json`, `SMOKE.json`. The route
  and beans are written by the implementer inside `flows`/`review`, not by you.
- Never run `rm`, except `rm "$EXPORT"` right after a `flows` run that printed the task1 line
  `events -> …/task1/events.masked.csv`, and only when that masked file exists.
- Never run `oc apply`, `git push`, `curl` to anything but `127.0.0.1`, or anything that leaves the VDI.
- Never print message values, payload fields, names of people, or the content of a parity case: counts and file
  names only. When a log line contains a value, quote the line's first 10 characters at most.
- A failing gate is not yours to fix: `flows`/`review` call the implementer; after two identical results you stop.
- Do not install software, change `~/.m2/settings.xml`, or edit `.osb-kit.env` (the person does, see traps.md).
- Time: `flows` can take an hour with a slow model. Wait for it; do not start a second one.
- Never run `card_answers.py` (with or without `--defaults`), `MUTATION_ACCEPTED.md` or any other answer on a person's behalf: at a HUMAN gate print the command the state gives and stop.
