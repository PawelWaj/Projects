---
description: "OSB proxy -> shareable research pack (no code, no hosts, no data)"
argument-hint: "<osb-project-dir> <proxy> [task1-dir]"
---
Act as the researcher defined in agents/researcher.md and follow AGENTS.md.
Use skill osb-research on the OSB export $1 for proxy $2 (scenarios from $3/traces/scenarios.json if given).
Write research/$2/RESEARCH.md and research/$2/research.json, run the share check until it passes, then give the five-line report.
