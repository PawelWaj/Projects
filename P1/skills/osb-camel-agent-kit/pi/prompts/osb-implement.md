---
description: Approved flow card -> Camel on Spring Boot code (implementer role)
argument-hint: "<flow> <module-dir>"
---
Act as the implementer defined in agents/implementer.md and follow AGENTS.md.
Refuse unless migration/$1/FLOW_CARD.md says Status approved with an approver.
Implement it with skill osb-to-camel Step 2 into Maven module $2. Never touch $2/src/test.
Finish when `mvn -q -DskipTests -f $2/pom.xml package` passes.
