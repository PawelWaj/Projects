#!/usr/bin/env python3
"""Regenerate the paste-install scripts for a VDI without file transfer (one quoted heredoc per file, nothing is
expanded by the shell). Run from the repo root after any change:

    python3 vdi-osb-migration/bin/build_bootstrap.py

Writes skills/osb-camel-agent-kit/bootstrap/<n>_install_<part>.sh (1-7). Paste each script into the migration workspace root on the
VDI (`cat > 1_install_agents.sh`, paste, Ctrl-D, `bash 1_install_agents.sh`), in order. Each ends with
`installed: N files`; if that line is missing the paste was truncated. Layout after install (workspace root = KIT):
AGENTS.md, agents/, pi/, tools/, ci/, .pi/skills/<skill>/, .pi/prompts/osb-*.md, log-replay/ (osb-log-replay),
bin/ + RUNBOOK.md (this workflow). The same repo checked out with git needs none of this."""
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
KIT = REPO / "skills" / "osb-camel-agent-kit"
REPLAY = REPO / "osb-log-replay"
VDI = REPO / "vdi-osb-migration"
OUT = KIT / "bootstrap"


def marker(dest: str) -> str:
    return "KIT_EOF_" + re.sub(r"[^A-Za-z0-9]", "_", dest).upper()


def files_under(root: pathlib.Path, patterns: list[str]) -> list[pathlib.Path]:
    out = []
    for pat in patterns:
        out += [p for p in sorted(root.glob(pat)) if p.is_file() and ".ruff_cache" not in p.parts and "__pycache__" not in p.parts]
    seen, uniq = set(), []
    for p in out:
        if p not in seen:
            seen.add(p)
            uniq.append(p)
    return uniq


def emit(name: str, what: str, items: list[tuple[pathlib.Path, str]], post: list[str], done: str) -> None:
    lines = ["#!/usr/bin/env bash", f"# Paste into the migration workspace root on the VDI and run: bash {name}", f"# {what}",
             "set -euo pipefail"]
    for src, dest in items:
        text = src.read_text(encoding="utf-8")
        if not text.endswith("\n"):
            text += "\n"
        m = marker(dest)
        if m in text:
            sys.exit(f"{src} contains its own end marker {m}")
        lines += [f'mkdir -p "$(dirname "{dest}")"', f"cat > '{dest}' <<'{m}'", text.rstrip("\n"), m]
    lines += post + [f'echo "installed: {len(items)} files ({done})"']
    script = "\n".join(lines) + "\n"
    (OUT / name).write_text(script, encoding="utf-8")
    print(f"{name}: {len(items)} files, {len(script.encode()) // 1024} KB")


def main() -> None:
    OUT.mkdir(exist_ok=True)
    rel = lambda root, p: p.relative_to(root).as_posix()  # noqa: E731
    # 1 agents: kit root files, role prompts, pi runner + prompts (also copied to .pi/prompts where pi reads them)
    agents = files_under(KIT, ["AGENTS.md", "README.md", "TESTING.md", "TRIAL_GUIDE.md", "TRIAL_RESULTS_TEMPLATE.csv",
                               "agents/*.md", "pi/*.sh", "pi/*.md", "pi/prompts/*.md"])
    items = [(p, rel(KIT, p)) for p in agents] + [(p, ".pi/prompts/" + p.name) for p in files_under(KIT, ["pi/prompts/*.md"])]
    emit("1_install_agents.sh", "Agent layer: AGENTS.md, role prompts, pi runner, /osb-* prompt templates (kit + .pi/prompts). Existing files are overwritten.",
         items, ["chmod +x pi/*.sh 2>/dev/null || true",
                 'echo "commands /osb-* installed in .pi/prompts: start pi in this folder and trust the project (or pi --approve)"'],
         "agent layer")
    # 2 gates
    gates = files_under(KIT, ["tools/*.sh", "tools/*.py", "tools/*.xml", "ci/*"])
    emit("2_install_gates.sh", "Gate tools: verify_flow.sh (G1-G8, G10), check_matrix, check_oracle, golden_runner, mutate_transforms, compare_shadow, pom plugins, Jenkins stages.",
         [(p, rel(KIT, p)) for p in gates], ["chmod +x tools/*.sh tools/*.py 2>/dev/null || true"], "gate tools")
    # 3 + 4 skill osb-to-camel (core, templates) -> .pi/skills
    sk = KIT / "skills" / "osb-to-camel"
    core = files_under(sk, ["SKILL.md", "scripts/*.py", "references/*"])
    tpl = files_under(sk, ["assets/templates/**/*"])
    emit("3_install_skill_osb_core.sh", "Skill osb-to-camel: SKILL.md, scripts, references under .pi/skills/.",
         [(p, ".pi/skills/osb-to-camel/" + rel(sk, p)) for p in core],
         ["chmod +x .pi/skills/osb-to-camel/scripts/*.py 2>/dev/null || true"], "skill osb-to-camel: SKILL.md, scripts, references")
    rs = KIT / "skills" / "osb-research"
    emit("8_install_skill_osb_research.sh", "Skill osb-research (shareable research pack) under .pi/skills/ + researcher role + pi runner.",
         [(p, ".pi/skills/osb-research/" + rel(rs, p)) for p in files_under(rs, ["SKILL.md", "scripts/*.py", "references/*", "assets/*"])]
         + [(KIT / "agents/researcher.md", "agents/researcher.md"), (KIT / "pi/run_research.sh", "pi/run_research.sh"),
            (KIT / "pi/prompts/osb-research.md", ".pi/prompts/osb-research.md")],
         ["chmod +x .pi/skills/osb-research/scripts/*.py pi/run_research.sh 2>/dev/null || true"], "skill osb-research")
    ck = KIT / "skills" / "osb-camelk-route"
    emit("9_install_skill_osb_camelk.sh", "Skill osb-camelk-route (research pack -> Camel K YAML module + tests + gates) under .pi/skills/ + implementer role + pi runners (one flow, whole domain).",
         [(p, ".pi/skills/osb-camelk-route/" + rel(ck, p)) for p in files_under(ck, ["SKILL.md", "scripts/*.py", "references/*", "assets/templates/*"])]
         + [(KIT / "agents/implementer-camelk.md", "agents/implementer-camelk.md"), (KIT / "pi/run_camelk.sh", "pi/run_camelk.sh"),
            (KIT / "pi/run_domain.sh", "pi/run_domain.sh"), (KIT / "pi/run_research.sh", "pi/run_research.sh"),
            (KIT / "pi/preflight.sh", "pi/preflight.sh"), (KIT / "AGENTS.md", "AGENTS.md"),
            (KIT / "pi/prompts/osb-camelk.md", ".pi/prompts/osb-camelk.md")]
         + [(p, ".pi/skills/osb-research/" + rel(rs, p)) for p in files_under(rs, ["references/*", "assets/*"])],
         ["chmod +x .pi/skills/osb-camelk-route/scripts/*.py pi/*.sh 2>/dev/null || true"], "skill osb-camelk-route + domain runner")
    emit("4_install_skill_osb_templates.sh", "Skill osb-to-camel: assets/templates (Java, XQuery shim, mocks) under .pi/skills/.",
         [(p, ".pi/skills/osb-to-camel/" + rel(sk, p)) for p in tpl],
         ["chmod +x .pi/skills/osb-to-camel/assets/templates/mocks/*.sh 2>/dev/null || true"], "skill osb-to-camel: assets/templates")
    # 5 verification skill
    vk = KIT / "skills" / "camel-migration-verification"
    ver = files_under(vk, ["**/*"])
    emit("5_install_skill_verification.sh", "Skill camel-migration-verification under .pi/skills/.",
         [(p, ".pi/skills/camel-migration-verification/" + rel(vk, p)) for p in ver], [], "skill camel-migration-verification")
    # 6 log replay tools -> log-replay/
    lr = files_under(REPLAY, ["tools/*.py", "replay-config.json", "run_offline.sh", "templates/**/*", "mock/*", "mock/**/*",
                              "skill/**/*", "README.md", "docs/*.md"])
    emit("6_install_log_replay.sh", "osb-log-replay: Splunk logs -> masked test cases -> fixtures -> replay (log-replay/).",
         [(p, "log-replay/" + rel(REPLAY, p)) for p in lr], ["chmod +x log-replay/tools/*.py log-replay/*.sh log-replay/mock/*.sh 2>/dev/null || true"],
         "log replay tools")
    # 7 this workflow -> bin/ + RUNBOOK.md
    wf = files_under(VDI, ["bin/*", "RUNBOOK.md", "TASKS.md", "LOGS_END_TO_END.md", "ALL_FLOWS.md", "RESEARCH_PACK.md", "DOMAIN_RUN.md", "HOW_IT_WORKS.md"])
    emit("7_install_vdi_workflow.sh", "VDI workflow: bin/start_flow.sh (one entry point per flow), preflight, replay-config generator, RUNBOOK.md.",
         [(p, rel(VDI, p)) for p in wf], ["chmod +x bin/*.sh bin/*.py 2>/dev/null || true",
                                          'echo "next: bash bin/preflight_vdi.sh, then read RUNBOOK.md"'], "VDI workflow")


if __name__ == "__main__":
    main()
