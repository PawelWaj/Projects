---
description: Flow card + OSB evidence -> test suite (tester role; start a NEW session first)
argument-hint: "<flow> <module-dir> <osb-project-dir>"
---
Act as the tester defined in agents/tester.md and follow AGENTS.md. You have not seen the implementation reasoning.
Write the tests for flow $1 from migration/$1/FLOW_CARD.md and the OSB evidence in $3, with skill osb-to-camel Step 3
and skill camel-migration-verification. One test per matrix row (T-ID in the name). Expected files only from OSB,
listed in $2/src/test/resources/golden/MANIFEST.csv. Do not edit $2/src/main. Run `mvn -q -f $2/pom.xml verify`.
