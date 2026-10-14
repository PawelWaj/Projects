# Paste-install on the VDI (no file transfer needed)

Run each script from the migration repository root in Git Bash or WSL, in this order. Each one ends with an
`installed: N files` line; if that line is missing, the paste was truncated: paste that script again.

| Script | Installs | Size |
|---|---|---|
| `1_install_agents.sh` | AGENTS.md, TESTING.md, agents/*.md (role prompts), pi/run_flow.sh, pi/preflight.sh, pi/prompts + .pi/prompts (/osb-* commands) | 61 KB |
| `2_install_gates.sh` | tools/verify_flow.sh (G1-G8, G10), check_matrix, check_oracle, golden_runner, mutate_transforms, compare_shadow, pom plugins, Jenkins stages | 36 KB |
| `3_install_skill_osb_core.sh` | .pi/skills/osb-to-camel: SKILL.md, scripts, references | 139 KB |
| `4_install_skill_osb_templates.sh` | .pi/skills/osb-to-camel/assets/templates (Java, XQuery shim, interface mocks) | 114 KB |
| `5_install_skill_verification.sh` | .pi/skills/camel-migration-verification | 10 KB |
| `6_install_log_replay.sh` | log-replay/: Splunk logs -> keyed masking -> fixtures -> replay tools, mock stack, docs | 124 KB |
| `7_install_vdi_workflow.sh` | bin/start_flow.sh (one entry point per flow), preflight, replay-config generator, RUNBOOK.md | 32 KB |
| `8_install_skill_osb_research.sh` | .pi/skills/osb-research (shareable research pack), researcher role, pi/run_research.sh | 34 KB |
| `9_install_skill_osb_camelk.sh` | .pi/skills/osb-camelk-route (research pack → Camel K YAML module + tests + gates K1-K8), implementer role, pi/run_camelk.sh, pi/run_domain.sh (all proxies of an OSB application), AGENTS.md (Camel K) | 89 KB |

All nine are generated from the repository by `python3 vdi-osb-migration/bin/build_bootstrap.py` (run it after any change; the install round-trips byte-identical).

How to paste a script: in the VDI terminal type `cat > 1_install_agents.sh`, press Enter, paste, press Ctrl-D,
then `bash 1_install_agents.sh`. Afterwards: `pi/preflight.sh`, then start `pi` and check the startup header lists
AGENTS.md, both skills and the /osb-* prompts.
