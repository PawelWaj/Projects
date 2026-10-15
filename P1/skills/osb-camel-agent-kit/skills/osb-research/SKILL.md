---
name: osb-research
description: "Research one Oracle Service Bus proxy from its source on the client machine and produce a SHAREABLE research pack (no source code, no hosts, no credentials, no personal data) that someone without access to the source can turn into a Camel K route and tests. Use when asked to research, analyse, describe or explain an OSB proxy, pipeline, business service or XQuery for migration and the result must leave the client network, or when the user says osb-research."
---

# OSB research pack: the source stays, the knowledge travels

The OSB source cannot leave the client network. The people who design the Camel K route and the tests work outside it.
This skill turns one proxy into a research pack that carries everything they need and nothing they must not have:
facts extracted by a script, plus answers to a fixed questionnaire written in plain language and mapping tables.
A check script blocks the pack if it still contains code, hosts, credentials or personal data.

## Rules (apply to every line you write into the pack)

1. **No source code.** Never paste XQuery, XSLT, XSD, WSDL or OSB XML. Describe it: what it does, which fields it reads
   and writes (as paths), which functions it calls. A short XPath *condition* (one line, at most 200 characters) may be
   quoted when a branch depends on it.
2. **No infrastructure.** No host names, IP addresses, ports, credentials, service accounts or key material.
   Destinations by name only (queue/topic JNDI name, HTTP path, SOAP operation).
3. **No data.** No values from payloads, logs or test files. Field names, codes and enum values defined in the code
   (for example `businessTransaction = 'TYPE_A'`) are allowed; personal values never.
4. **Evidence for every answer.** Each answer names the file (path relative to the export) and the stage/action it
   comes from. If something cannot be determined from the source, write `UNKNOWN` and add it to open questions.
   Never guess.
5. Namespaces are referred to by prefix; their URIs are already in `facts.json`.

## Steps

1. **Facts (script, no judgement):**
   `python <skill>/scripts/research_pack.py <osb-export> <proxy> -o research/<proxy> [--scenarios task1/traces/scenarios.json]`
   Writes `facts.json` (sanitised inventory of the proxy) and `SOURCES.txt` (the files to read). Read `facts.json` first.
2. **Read the sources** listed in `SOURCES.txt`, plus every resource they reference (shared XQuery, DVM, schemas,
   Java callouts). Anything referenced but missing goes to open questions.
3. **Answer the questionnaire** in `references/questions.md`: write `research/<proxy>/RESEARCH.md` using
   `assets/RESEARCH_TEMPLATE.md` (same headings, same tables), and `research/<proxy>/research.json` following
   `assets/research.schema.json`. The two must agree.
4. **Check before sharing:**
   `python <skill>/scripts/research_check.py research/<proxy>`
   It must print `PASS`. On `FAIL`, rewrite the flagged lines (describe instead of quoting, drop the value) and rerun.
   Never delete a finding by weakening the check.
5. **Report**: five lines: proxy, tier, number of branches/backends/transforms, number of open questions, check result.
   The human shares only `RESEARCH.md`, `research.json`, `facts.json`, `SHARE_CHECK.json`.

## What the pack is used for (so you know what matters)

- **Selector, subscription, outputs** → the Camel K route's endpoints and the broker filter.
- **Branches with their conditions and the scenario values that trigger them** → one test group per branch; the
  scenarios from the Splunk logs (`log_scenarios` in `facts.json`) must each map to a branch.
- **Transform mappings (source path → target path → rule)** → the route's transformation and the reviewer's checklist;
  the expected outputs themselves are still computed on the client machine by running the original XQuery.
- **Backends with request/response use, retries, timeouts** → WireMock stubs and Artemis mocks.
- **Error handling per scope** → the error tests (what is caught, where it goes, which headers).
- **Log actions** → the same log lines in Camel so the existing Splunk searches keep working.
