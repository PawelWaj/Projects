# Using this skill with camel-kit

[camel-kit](https://github.com/luigidemasi/camel-kit) (Apache-2.0, v0.4.1 at the time of writing, actively developed)
installs a Spec-Kit-style workflow into Claude Code, Copilot, Codex and others: `/camel-start → /camel-migrate →
/camel-plan → /camel-execute → /camel-validate`, with a knowledge MCP for the Camel catalog, a project graph, Citrus
tests, and a set of "iron laws" (design approval before code, catalog verification of every component, adversarial
review). Its `/camel-migrate` has vendor adapters for MuleSoft, BizTalk, Camel 2/3 and JBoss Fuse. **It has no OSB
adapter**, no OSB parser in `camel-kit-graph`, and its examples contain no OSB artefact.

This skill is the OSB adapter in camel-kit's shape, written so that it works standalone and can slot into the camel-kit
pipeline without re-explaining itself.

## Correspondence

| camel-kit concept | This skill |
|---|---|
| Vendor detection row (`camel-migrate/SKILL.md` Step 3) | OSB signals: files `.proxy`/`.pipeline`/`.bix` (12c project) or `.ProxyService`/`.Pipeline`/`.BusinessService` (sbconfig export); root namespaces `http://www.bea.com/wli/sb/services`, `http://www.bea.com/wli/sb/pipeline/config`; `fn-bea:` in XQuery |
| Graph acceleration (`camel-kit-graph` parsers; `graph stats` node types) | `scripts/osb_inventory.py` → `inventory.json` and `dependencies.dot`. Node types to add upstream: `OSB_PROXY`, `OSB_PIPELINE`, `OSB_BUSINESS_SERVICE`, `OSB_TRANSFORM` |
| Phase 1 guide (`<vendor>-phase1.md`: inventory, adapters, business requirements) | Step 0 + the flow card's sections 1, 4, 7, 9; `osb-transport-mapping.md` plays the role of `<vendor>-component-mapping.md` |
| R1 behavioural analysis and source-retirement audit (`migration-analysis.md`, `source-retirement-audit.md`) | The inventory's `unreferenced_business_services`, `NOT FOUND` references and `chained_proxies` are the retirement-audit inputs; the card's section 6 and 7 carry the behavioural risks |
| Phase 2 guide (`<vendor>-phase2.md`: design spec per flow, sections 1–11) | The flow card is that per-flow design: contract, source, processing steps with a field-mapping audit trail, sink, error handling, configuration, dependencies, testing strategy, checklist |
| `<vendor>-expression-mapping.md`, `<vendor>-map-conversion.md`, `<vendor>-pipeline-mapping.md` | `osb-expression-mapping.md` (XQuery/XSLT/context), `osb-action-mapping.md` (pipeline) |
| `camel-plan` task template for migrations | Steps 2–4 of SKILL.md, one task per flow; in camel-kit, the plan generates them |
| `camel-execute` (implementation under iron laws) | Step 2, standalone. Inside camel-kit, do **not** generate code from this skill; hand the card to the plan and let `camel-execute` implement, loading `osb-*-mapping.md` as implementer context |
| `camel-test` (Citrus YAML + Testcontainers) | `test-strategy.md` (JUnit 5 + AdviceWith + WireMock + Testcontainers). Both can coexist |
| `camel-validate` static gate | Run it on the generated module if routes are YAML; for Java DSL, the constitution checks (route ids, descriptions, placeholders, no hardcoded endpoints) are in the templates and the record's checklist |
| `shared/flow-test-data.md` fixture rules | The fixture rules in `test-strategy.md` follow the same naming and value conventions on purpose |

## Two deliberate differences

1. **Java DSL on Spring Boot, not YAML DSL on Camel Main.** The programme's integration code lives inside Spring Boot
   domain services maintained by Java teams, and `AdviceWith`-based isolation of pipeline branches is a Java-side
   capability. camel-kit supports the Spring Boot runtime; its Ship controller and some validators prefer YAML. If a
   team adopts camel-kit fully, the card is runtime-neutral and the mapping tables carry a YAML column where it matters.
2. **No MCP catalog gate inside this skill.** camel-kit's Iron Law 1 verifies every component against the Camel
   catalog through its knowledge MCP. Standalone, this skill pins components and versions in `versions.md`; when the MCP
   is available, verify the components the card proposes before generating code, exactly as the iron law asks.

## Running inside a camel-kit project

1. `camel-kit init --here --ai claude` in the target repository (installs its skills under `.claude/`).
2. Copy this skill next to them (`.claude/skills/osb-to-camel/`), or keep it user-scoped.
3. Run `/camel-start` and point it at the OSB export; when it reports an unknown vendor, invoke this skill's Step 0 and
   Step 1 to produce the cards, then feed `/camel-plan` with the cards as the approved design package
   (`business-requirements.md` = inventory summary + scope; `design-spec.md` = the cards; `migration-analysis.md` =
   the open items and retirement audit).
4. Let `/camel-execute` implement with `references/osb-*.md` as context, and run both test suites.

## Contributing upstream

The adapter is deliberately shaped like `biztalk-*.md`. To contribute it: `osb-phase1.md` (from SKILL.md Step 0–1 and
the card template), `osb-phase2.md` (from the card's design sections), `osb-action-mapping.md`,
`osb-expression-mapping.md`, `osb-transport-mapping.md` as shared guides, a vendor row in `camel-migrate/SKILL.md`,
and an `OsbParser` in `camel-kit-graph` porting `osb_inventory.py`. The `examples/osb-contributor-enquiry/` fixture in
`evals/fixtures/` is a ready example project.
