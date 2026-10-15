"""Tests for the VDI workflow tools. Run from the repo root: python3 -m unittest discover -s vdi-osb-migration/tests -v"""
import csv
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BIN = ROOT / "vdi-osb-migration" / "bin"
KIT = ROOT / "skills" / "osb-camel-agent-kit"
SKILL = KIT / "skills" / "osb-to-camel"
FIXTURE_TOPIC = SKILL / "evals" / "fixtures" / "osb-export-12c-topic"
FIXTURE_SOAP = SKILL / "evals" / "fixtures" / "osb-export" / "ContributorIntegration"
REPLAY = ROOT / "osb-log-replay"


def run(*args, check=True, env=None):
    return subprocess.run([sys.executable, *map(str, args)], capture_output=True, text=True, check=check, env=env)


def saxon_jar():
    if os.environ.get("SAXON_JAR"):
        return Path(os.environ["SAXON_JAR"])
    jars = sorted((Path.home() / ".m2/repository/net/sf/saxon/Saxon-HE").glob("*/Saxon-HE-*.jar"))
    return jars[-1] if jars else None


class ReplayConfigTests(unittest.TestCase):
    def inventory(self, fixture, d):
        run(SKILL / "scripts/osb_inventory.py", fixture, "-o", d / "inv")
        return sorted((d / "inv/flows").glob("*.json"))

    def test_jms_topic_flow_is_drafted_with_selector_and_negatives(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            flow = self.inventory(FIXTURE_TOPIC, d)[0]
            out = run(BIN / "replay_config_from_inventory.py", flow, "-o", d / "replay-config.json")
            cfg = json.loads((d / "replay-config.json").read_text())
            key = json.loads(out.stdout)["flow"]
            self.assertEqual(key, "order-event-prj/order-event")
            e = cfg["flows"][key]
            self.assertEqual(e["input"]["address"], "orderEventsTopic")
            self.assertEqual(e["input"]["type"], "multicast")
            self.assertIn("resource='Create Order'", e["input"]["filter"])
            self.assertEqual(e["outputs"]["success"]["destination"], "InboundOrderEventQueue")
            self.assertEqual(e["outputs"]["error"]["destination"], "orderEventErrorQueue")
            self.assertEqual({c["headers"]["resource"] for c in e["negative_cases"]} & {"not-Create Order"}, {"not-Create Order"})
            self.assertTrue(any("TARGET broker names" in t for t in e["_todo"]))
            # a hand-completed entry (no _todo) is never overwritten
            del cfg["flows"][key]["_todo"]
            (d / "replay-config.json").write_text(json.dumps(cfg))
            out = run(BIN / "replay_config_from_inventory.py", flow, "-o", d / "replay-config.json")
            self.assertEqual(json.loads(out.stdout)["status"], "kept")

    def test_http_inbound_is_marked_unsupported(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            flow = self.inventory(FIXTURE_SOAP, d)[0]
            run(BIN / "replay_config_from_inventory.py", flow, "-o", d / "rc.json", "--project", "ContributorIntegration")
            self.assertIn("_unsupported", json.loads((d / "rc.json").read_text())["flows"]["ContributorIntegration/ContributorEnquiryPS"])


class GoldenRunnerTests(unittest.TestCase):
    QUERY = ('xquery version "1.0";\n'
             'declare namespace fn-bea = "http://www.bea.com/xquery/xquery-functions";\n'
             'declare variable $body as element() external;\n'
             '<out><id>{ data($body/id) }</id><upper>{ upper-case(data($body/name)) }</upper>'
             '<when>{ fn-bea:date-to-string-with-format("yyyy-MM-dd", xs:date("2026-01-15")) }</when></out>')

    def make_resources(self, d: Path, payload: str):
        case = d / "res/parity/sample-flow/success/t1"
        case.mkdir(parents=True)
        (case / "input.payload").write_text(payload, encoding="utf-8")
        (case / "headers.json").write_text('{"traceId": "t1"}', encoding="utf-8")
        (d / "orig.xqy").write_text(self.QUERY, encoding="utf-8")
        return d / "res"

    @unittest.skipUnless(saxon_jar() and shutil.which("java"), "needs Saxon-HE in ~/.m2 and java")
    def test_run_writes_expected_output_lock_and_manifest_then_check_detects_tampering(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            res = self.make_resources(d, "<doc><id>7</id><name>abc</name></doc>")
            out = run(KIT / "tools/golden_runner.py", "run", res, "--transform", d / "orig.xqy",
                      "--shim", SKILL / "assets/templates/xquery/fn-bea-shim.xqy", "--saxon", saxon_jar())
            self.assertEqual(json.loads(out.stdout)["ok"], 1, out.stdout)
            expected = (res / "parity/sample-flow/success/t1/expected-output.xml").read_text()
            self.assertIn("<upper>ABC</upper>", expected)
            self.assertIn("<when>2026-01-15</when>", expected)
            manifest = (res / "golden/MANIFEST.csv").read_text()
            self.assertIn("original-transform", manifest)
            self.assertIn("sha256", manifest.splitlines()[0])
            self.assertEqual(run(KIT / "tools/golden_runner.py", "check", res).returncode, 0)
            # tampering (an expected file produced by anything else) is caught by G10
            (res / "parity/sample-flow/success/t1/expected-output.xml").write_text("<out>hand written</out>")
            r = run(KIT / "tools/golden_runner.py", "check", res, check=False)
            self.assertEqual(r.returncode, 1)
            self.assertIn("expected output changed", r.stdout)
            # an expected-output.xml nobody locked is caught too
            extra = res / "parity/sample-flow/success/t2"
            extra.mkdir()
            (extra / "expected-output.xml").write_text("<x/>")
            r = run(KIT / "tools/golden_runner.py", "check", res, check=False)
            self.assertIn("expected_outputs_not_in_lock", r.stdout)
            self.assertIn("t2", r.stdout)

    @unittest.skipUnless(saxon_jar() and shutil.which("java"), "needs Saxon-HE in ~/.m2 and java")
    def test_json_input_is_oracle_blocked_not_fabricated(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            res = self.make_resources(d, '{"data": {"id": 7}}')
            r = run(KIT / "tools/golden_runner.py", "run", res, "--transform", d / "orig.xqy", "--saxon", saxon_jar(), check=False)
            self.assertEqual(r.returncode, 3)
            lock = json.loads((res / "golden/ORACLE.lock").read_text())
            self.assertEqual(lock["entries"][0]["status"], "oracle-blocked")
            self.assertFalse((res / "parity/sample-flow/success/t1/expected-output.xml").exists())

    def test_check_without_lock_fails(self):
        with tempfile.TemporaryDirectory() as d:
            r = run(KIT / "tools/golden_runner.py", "check", d, check=False)
            self.assertEqual(r.returncode, 1)


class KitGateScriptTests(unittest.TestCase):
    def test_check_oracle_requires_reason_and_approver_for_source_derived(self):
        with tempfile.TemporaryDirectory() as d:
            res = Path(d)
            (res / "parity/f").mkdir(parents=True)
            (res / "parity/f/a.xml").write_text("<a/>")
            (res / "parity/f/b.xml").write_text("<b/>")
            (res / "golden").mkdir()
            (res / "golden/MANIFEST.csv").write_text(
                "file,source,flow,captured_by,date,reason,approved_by\n"
                "parity/f/a.xml,source-derived,f,me,2026-01-01,no traffic in window,reviewer\n"
                "parity/f/b.xml,source-derived,f,me,2026-01-01,,\n")
            r = run(KIT / "tools/check_oracle.py", res, check=False)
            self.assertEqual(r.returncode, 1)
            rep = json.loads(r.stdout)
            self.assertEqual(len(rep["bad_source"]), 1)
            self.assertIn("b.xml", rep["bad_source"][0])

    def test_verify_flow_script_parses_and_resolves_python(self):
        r = subprocess.run(["bash", "-n", str(KIT / "tools/verify_flow.sh")], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        src = (KIT / "tools/verify_flow.sh").read_text()
        self.assertIn('command -v python3 || command -v python || command -v py', src)
        self.assertIn("IT_SKIP", src)
        self.assertIn("G10", src)

    def test_run_flow_orders_tests_before_implementation(self):
        src = (KIT / "pi/run_flow.sh").read_text()
        self.assertLess(src.index("S2 test"), src.index("S3 implement"))
        self.assertIn("--from test", src)
        r = subprocess.run(["bash", "-n", str(KIT / "pi/run_flow.sh")], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)


if __name__ == "__main__":
    unittest.main()


class TestCatalogTests(unittest.TestCase):
    def test_task1_output_becomes_catalogue(self):
        if not shutil.which("bash"):
            self.skipTest("bash not available")
        with tempfile.TemporaryDirectory() as d:
            env = dict(os.environ, MASK_KEY="k", PYTHON=sys.executable,
                       SCENARIO_DIMS="hdr_resource,body:data.businessTransaction")
            sample = ROOT / "osb-log-replay" / "samples" / "splunk-export-synthetic.csv"
            r = subprocess.run(["bash", str(BIN / "task1_log_only.sh"), str(sample), str(Path(d) / "t")],
                               capture_output=True, text=True, env=env)
            self.assertEqual(r.returncode, 0, r.stderr)
            out = subprocess.run([sys.executable, str(BIN / "test_catalog.py"), str(Path(d) / "t"),
                                  "--negative-resource", "Other Resource", "--fanout-peer", "peer"],
                                 capture_output=True, text=True, check=True)
            info = json.loads(out.stdout)
            self.assertEqual((info["parity"], info["case_folders_with_problems"]), (1, 0))
            md = (Path(d) / "t" / "TEST_CATALOG.md").read_text(encoding="utf-8")
            for tid in ("P01", "S01", "S02", "F01", "E01", "D01"):
                self.assertIn(f"| {tid} |", md)
            neg = json.loads((Path(d) / "t" / "negative-cases.json").read_text(encoding="utf-8"))
            self.assertEqual(neg[0]["headers"], {"resource": "Other Resource"})


class BatchTask1Tests(unittest.TestCase):
    def test_three_flows_one_export(self):
        import csv as _csv
        import uuid
        raw = next(_csv.DictReader((ROOT / "osb-log-replay/samples/splunk-export-synthetic.csv").open(encoding="utf-8")))["_raw"]

        def mk(prj, ps, res, bt):
            r = raw.replace("Project sample-change-prj :: for PS sample-adjustment", f"Project {prj} :: for PS {ps}")
            r = r.replace("Sample Resource event", f"{res} event").replace("TYPE_B", bt)
            return r.replace("99999999-8888-4777-8666-555555555555", str(uuid.uuid4()))
        lines = [mk("a-prj", "a", "Wage", ["X_ONE", "X_TWO"][i % 2]) for i in range(6)]
        lines += [mk("b-prj", "b", "Wage", "X_ONE") for _ in range(3)] + [mk("c-prj", "c", "Transfer", "T_IN") for _ in range(3)]
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "all.csv"
            with f.open("w", encoding="utf-8", newline="") as fh:
                w = _csv.writer(fh, quoting=_csv.QUOTE_ALL)
                w.writerow(["_time", "_raw"])
                w.writerows(["t", l] for l in lines)
            r = subprocess.run([sys.executable, str(BIN / "batch_task1.py"), str(f), "-o", str(Path(d) / "out")],
                               capture_output=True, text=True, env=dict(os.environ, MASK_KEY="k"))
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            info = json.loads(r.stdout.strip().splitlines()[-1])
            self.assertEqual((info["flows"], info["ok"]), (3, 3))
            topics = json.loads((Path(d) / "out/topics.json").read_text(encoding="utf-8"))
            self.assertEqual(topics["a-prj/a"]["negatives"], ["Transfer"])
            self.assertEqual(topics["a-prj/a"]["fanout"], ["b"])
            dims = json.loads((Path(d) / "out/flows/a-prj-a/dims.json").read_text(encoding="utf-8"))["chosen"]
            self.assertIn("body:data.businessTransaction", dims)
            self.assertTrue((Path(d) / "out/SUMMARY.md").is_file())


class ResearchPackTests(unittest.TestCase):
    SK = ROOT / "skills/osb-camel-agent-kit/skills/osb-research/scripts"
    FIX = ROOT / "skills/osb-camel-agent-kit/skills/osb-to-camel/evals/fixtures/osb-export"

    def test_facts_are_sanitised_and_pass_the_share_check(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "r"
            subprocess.run([sys.executable, str(self.SK / "research_pack.py"), str(self.FIX), "ContributorEnquiryPS", "-o", str(out)],
                           check=True, capture_output=True, text=True)
            facts = (out / "facts.json").read_text(encoding="utf-8")
            self.assertNotIn("://", json.dumps([s["destinations"] for s in json.loads(facts)["business_services"]]))
            self.assertIn("ContributorIntegration/Transform/MemberToContributor.xqy", (out / "SOURCES.txt").read_text())
            ok = subprocess.run([sys.executable, str(self.SK / "research_check.py"), str(out)], capture_output=True, text=True)
            self.assertEqual(ok.returncode, 0, ok.stdout)
            self.assertTrue(json.loads((out / "SHARE_CHECK.json").read_text())["pass"])

    def test_share_check_blocks_code_hosts_secrets_and_data(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "RESEARCH.md").write_text(
                "host http://osb01.client.internal:7001/sbconsole\npassword = hunter22\nid 1234567890\n"
                "```\nxquery version \"1.0\";\n```\n", encoding="utf-8")
            r = subprocess.run([sys.executable, str(self.SK / "research_check.py"), d], capture_output=True, text=True)
            self.assertEqual(r.returncode, 1)
            rules = json.loads((Path(d) / "SHARE_CHECK.json").read_text())["findings_per_rule"]
            self.assertEqual(set(rules), {"host", "secret", "pii", "code"})
            self.assertNotIn("hunter22", r.stdout)                      # findings never print the value


class CamelkRouteTests(unittest.TestCase):
    """scaffold_camelk.py + check_camelk.py on a pack shaped like the pilot's (fake names)."""
    SK = ROOT / "skills/osb-camel-agent-kit/skills/osb-camelk-route/scripts"
    PACK = {
        "proxy": "px", "entry": {"destination": "jndi.inTopic", "is_topic": True, "durable_subscription": "true", "payload_format": "json"},
        "scenario_dims": ["data.flagA", "data.flagB"],
        "branches": [{"name": "A check", "paths": [{"label": "A", "condition_plain": "flagA true", "outputs": ["svc-a"]}]},
                     {"name": "B check", "paths": [{"label": "B", "condition_plain": "flagB true", "outputs": ["jndi.qB"]}]}],
        "scenario_mapping": [{"scenario": "flagA=true|flagB=true", "outputs": ["svc-a", "svc-b"]},
                             {"scenario": "flagA!=true|flagB!=true", "outputs": []}],
        "outputs": [{"name": "A out", "destination": "jndi.qA"}, {"name": "B out", "destination": "jndi.qB"},
                    {"name": "error out", "destination": "jndi.qErr", "on": "error handler"}],
        "backends": [{"name": "svc-a", "type": "JMS queue", "operation": "jndi.qA"}, {"name": "svc-b", "type": "JMS queue", "operation": "jndi.qB"},
                     {"name": "svc-err", "type": "JMS queue", "operation": "jndi.qErr"}],
        "errors": [{"scope": "pipeline", "goes_to": "svc-err"}],
        "logs": [{"stage": "s1", "level": "INFO", "template": "Request {x}"}, {"stage": "error stage", "template": "Error {x}"}],
        "open_questions": ["q1"]}

    def test_scaffold_normalises_outputs_and_check_flags_gaps(self):
        with tempfile.TemporaryDirectory() as d:
            res, mod = Path(d, "res"), Path(d, "mod")
            res.mkdir()
            (res / "research.json").write_text(json.dumps(self.PACK), encoding="utf-8")
            r = subprocess.run([sys.executable, str(self.SK / "scaffold_camelk.py"), str(res), "-o", str(mod), "--project", "p-prj"],
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            cfg = json.loads((mod / "src/test/resources/flow-test.json").read_text())
            self.assertEqual(sorted(cfg["outputs"]), ["svc-a", "svc-b", "svc-err"], "JMS backends are outputs, keyed by service")
            self.assertEqual(cfg["backends"], {})
            self.assertEqual(cfg["error_output"], "svc-err")
            self.assertEqual(cfg["scenario_mapping"][0]["outputs"], ["svc-a", "svc-b"])
            props = (mod / "src/main/resources/application.properties").read_text()
            self.assertIn("flow.input=amqp:queue:jndi.inTopic::px", props)
            route = (mod / "src/main/resources/routes/px.camel.yaml").read_text()
            self.assertIn("id: out-svc-b", route)
            self.assertLess(route.index("doCatch"), route.index("Error {x}"), "error-stage log goes into the catch")
            bean = next(mod.rglob("OsbJson.java")).read_text()
            self.assertIn('{"flagA", "data.flagA"}', bean)
            c = subprocess.run([sys.executable, str(self.SK / "check_camelk.py"), str(mod), "--no-surefire"], capture_output=True, text=True)
            self.assertEqual(c.returncode, 1)
            gates = json.loads((mod / "GATES.json").read_text())["gates"]
            self.assertFalse(gates["K1_card_approved"]["ok"])
            self.assertFalse(gates["K2_no_gaps"]["ok"])
            self.assertTrue(gates["K3_route_ids"]["ok"])
            self.assertTrue(gates["K4_no_infrastructure"]["ok"])
            self.assertFalse(gates["K7_error_tests"]["ok"])
            # editing a generated test is caught; a host in the properties is caught
            t = next(mod.rglob("FlowParityTest.java"))
            t.write_text(t.read_text() + "\n// weakened\n")
            (mod / "src/main/resources/application.properties").write_text(props + "x=amqp://broker.example.com:5672\n")
            subprocess.run([sys.executable, str(self.SK / "check_camelk.py"), str(mod), "--no-surefire"], capture_output=True)
            gates = json.loads((mod / "GATES.json").read_text())["gates"]
            self.assertFalse(gates["K5_tests_untouched"]["ok"])
            self.assertFalse(gates["K4_no_infrastructure"]["ok"])

    def test_pilot_module_passes_static_gates_except_approval(self):
        mod = ROOT / "pilot/sample-adjustment"
        with tempfile.TemporaryDirectory() as d:
            m = Path(d, "m")
            shutil.copytree(mod, m, ignore=shutil.ignore_patterns("target"))
            subprocess.run([sys.executable, str(self.SK / "check_camelk.py"), str(m), "--no-surefire"], capture_output=True)
            gates = json.loads((m / "GATES.json").read_text())["gates"]
            self.assertEqual([k for k, g in gates.items() if not g["ok"]], ["K1_card_approved"])


if __name__ == "__main__":
    unittest.main()


class TestMatrixTests(unittest.TestCase):
    """test_matrix.py joins case folders, surefire display names and mapping into P/E rows (no values read)."""
    SK = ROOT / "skills/osb-camel-agent-kit/skills/osb-camelk-route/scripts"

    def test_rows_from_reports(self):
        with tempfile.TemporaryDirectory() as d:
            m = Path(d)
            (m / "src/test/resources").mkdir(parents=True)
            (m / "src/test/resources/flow-test.json").write_text(json.dumps({
                "outputs": {"a": "mock:out-a", "err": "mock:out-err"}, "error_output": "err",
                "scenario_mapping": [{"scenario": "f=true", "outputs": ["a"]}, {"scenario": "f!=true", "outputs": []}]}))
            (m / ".scaffold.json").write_text(json.dumps({"project": "p", "proxy": "x"}))
            for sc, val in (("s1", "true"), ("s2", "false")):
                c = m / "src/test/resources/parity/flow" / sc / "t1"
                c.mkdir(parents=True)
                (c / "input.payload").write_text("{}")
                (c.parent / "SCENARIO.txt").write_text(f"p/x|success|f={val}\n")
            (m / "target/surefire-reports").mkdir(parents=True)
            (m / "target/surefire-reports/TEST-a.xml").write_text(
                '<testsuite><testcase classname="o.FlowParityTest" name="reachesTheSameOutputAsOsb(String, Path) route flow/s1/t1"/>'
                '<testcase classname="o.FlowParityTest" name="reachesTheSameOutputAsOsb(String, Path) route flow/s2/t1"><failure/></testcase>'
                '<testcase classname="o.FlowErrorTest" name="retriesThreeTimes"/></testsuite>')
            r = subprocess.run([sys.executable, str(self.SK / "test_matrix.py"), str(m)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 1, "a failed case fails the matrix")
            rows = list(csv.DictReader((m / "test-matrix.csv").open()))
            p = {x["what"]: x for x in rows if x["id"].startswith("P")}
            self.assertEqual(p["f=true"]["expected"], "out-a")
            self.assertEqual(p["f=false"]["expected"], "nothing sent")
            self.assertEqual(p["f=false"]["result"], "FAIL")
            self.assertTrue(any(x["kind"] == "error/behaviour" and x["result"] == "PASS" for x in rows))


if __name__ == "__main__":
    unittest.main()


class SyntheticAndReplyTests(unittest.TestCase):
    """Request/reply flows get a 'reply' output; synthetic cases close gate K9 and are frozen (K5); coverage groups."""
    SK = ROOT / "skills/osb-camel-agent-kit/skills/osb-camelk-route/scripts"
    PACK = {"proxy": "get-status", "entry": {"transport": "http", "payload_format": "json"}, "scenario_dims": ["data.kind"],
            "branches": [], "scenario_mapping": [{"scenario": "kind=A", "outputs": ["reply"]}],
            "outputs": [{"name": "err", "destination": "jndi.errQ", "on": "error handler"}],
            "backends": [], "errors": [{"scope": "pipeline"}], "logs": [], "open_questions": []}

    def test_reply_synthetic_freeze(self):
        with tempfile.TemporaryDirectory() as d:
            res, mod = Path(d, "res"), Path(d, "mod")
            res.mkdir()
            (res / "research.json").write_text(json.dumps(self.PACK))
            run = lambda *a: subprocess.run([sys.executable, *map(str, a)], capture_output=True, text=True)  # noqa: E731
            self.assertEqual(run(self.SK / "scaffold_camelk.py", res, "-o", mod, "--project", "s-prj").returncode, 0)
            cfg = json.loads((mod / "src/test/resources/flow-test.json").read_text())
            self.assertEqual(cfg["outputs"]["reply"], "reply")
            self.assertNotIn("out.reply", (mod / "src/main/resources/application.properties").read_text())
            run(self.SK / "check_camelk.py", mod, "--no-surefire")
            self.assertFalse(json.loads((mod / "GATES.json").read_text())["gates"]["K9_scenarios_covered"]["ok"])
            c = mod / "src/test/resources/parity/s-prj-get-status-synthetic/kind-a/c1"
            c.mkdir(parents=True)
            (c.parent / "SCENARIO.txt").write_text("s-prj/get-status|success|kind=A\n")
            (c / "input.payload").write_text('{"data":{"kind":"A"}}')
            self.assertIn('"frozen_synthetic_files": 2', run(self.SK / "scaffold_camelk.py", res, "-o", mod, "--project", "s-prj", "--freeze-synthetic").stdout)
            run(self.SK / "scaffold_camelk.py", res, "-o", mod, "--project", "s-prj")          # a rerun keeps the frozen hashes
            (c / "input.payload").write_text('{"data":{"kind":"A","x":1}}')
            run(self.SK / "check_camelk.py", mod, "--no-surefire")
            g = json.loads((mod / "GATES.json").read_text())["gates"]
            self.assertTrue(g["K9_scenarios_covered"]["ok"])
            self.assertFalse(g["K5_tests_untouched"]["ok"], "an edited synthetic case is caught")

    def test_domain_coverage_groups(self):
        with tempfile.TemporaryDirectory() as d:
            inv = Path(d, "inv")
            subprocess.run([sys.executable, str(ROOT / "skills/osb-camel-agent-kit/skills/osb-to-camel/scripts/osb_inventory.py"),
                            str(ROOT / "skills/osb-camel-agent-kit/skills/osb-to-camel/evals/fixtures/osb-export-12c-topic"), "-o", str(inv)],
                           capture_output=True)
            Path(d, "s.csv").write_text("project,proxy,payload,count\norder-event-prj,order-event,json,5\n")
            r = subprocess.run([sys.executable, str(ROOT / "vdi-osb-migration/bin/domain_coverage.py"), str(inv), str(Path(d, "s.csv")),
                                "-o", str(Path(d, "COVERAGE.md"))], capture_output=True, text=True)
            self.assertIn('"A real inputs": 1', r.stdout)


if __name__ == "__main__":
    unittest.main()


class LoggedOutputOracleTests(unittest.TestCase):
    """A '... for BS x ... ::<body>' line in the same trace becomes expected-output.* of that case."""

    def test_outbound_line_becomes_expected_output(self):
        src = list(csv.DictReader(open(ROOT / "osb-log-replay/samples/splunk-export-synthetic.csv", encoding="utf-8")))[0]
        raw = src["_raw"]
        pre = raw[:raw.index("[sample-change-pipelinepairnode")]
        with tempfile.TemporaryDirectory() as d:
            rows = []
            for i in range(2):
                tid = f"99999999-8888-4777-8666-55555555555{i}"
                rows.append({"_time": src["_time"], "_raw": pre + "[p, r, s, REQUEST] Request Received to Project sample-change-prj :: for PS "
                             f"sample-adjustment from JMS t for Resource Name: R event with TraceID - {tid} ::" + '{"data":{"k":"A"}}'})
                rows.append({"_time": src["_time"], "_raw": pre + "[p, r, RouteNode, REQUEST] Request from Project sample-change-prj :: for BS "
                             f"bs to be posted to Q with TraceID: {tid} ::<x:R xmlns:x=\"urn:x\"><x:n>{i}</x:n></x:R>"})
            with open(Path(d, "ex.csv"), "w", newline="", encoding="utf-8") as fh:
                w = csv.DictWriter(fh, fieldnames=["_time", "_raw"])
                w.writeheader()
                w.writerows(rows)
            r = subprocess.run([sys.executable, str(ROOT / "vdi-osb-migration/bin/batch_task1.py"), str(Path(d, "ex.csv")), "-o", str(Path(d, "b"))],
                               capture_output=True, text=True, env={**os.environ, "MASK_KEY": "t"})
            self.assertIn('"flows": 1', r.stdout, r.stdout + r.stderr)
            outs = sorted(Path(d, "b").rglob("expected-output.xml"))
            self.assertEqual(len(outs), 2)
            self.assertIn("<x:n>", outs[0].read_text())
            self.assertFalse(list(Path(d, "b").rglob("input.payload"))[0].read_text().startswith("<"), "input stays the request")


if __name__ == "__main__":
    unittest.main()


class DomainReportTests(unittest.TestCase):
    """domain_report.py: per-flow proof columns and the 'proven' count from status, packs, modules and reports."""

    def test_report_counts_and_gaps(self):
        with tempfile.TemporaryDirectory() as d:
            ws = Path(d)
            (ws / "domain").mkdir()
            (ws / "domain/status.csv").write_text("project,proxy,research,open_questions,test_cases,card,gates,tests\np,x,PASS,0,1,approved,PASS,1\np,y,-,-,-,-,-,-\n")
            (ws / "research/p/x").mkdir(parents=True)
            (ws / "research/p/x/research.json").write_text(json.dumps({"transforms": [], "open_questions": []}))
            (ws / "research/p/x/SHARE_CHECK.json").write_text('{"pass": true}')
            m = ws / "modules/p/x"
            (m / "src/test/resources/parity/f/s/c1").mkdir(parents=True)
            (m / "src/test/resources/parity/f/s/c1/input.payload").write_text("{}")
            (m / "src/test/resources/flow-test.json").write_text(json.dumps({"outputs": {"a": "mock:out-a"}, "scenario_mapping": [{"scenario": "*", "outputs": ["a"]}]}))
            (m / "target/surefire-reports").mkdir(parents=True)
            (m / "target/surefire-reports/TEST-a.xml").write_text('<testsuite tests="3" failures="0" errors="0" skipped="0"/>')
            (m / "MUTATION.json").write_text('{"killed": 2, "total": 2}')
            (m / "FLOW_CARD.md").write_text("Approve by setting `Status: approved` ...\nStatus: approved\n")
            r = subprocess.run([sys.executable, str(ROOT / "skills/osb-camel-agent-kit/skills/osb-camelk-route/scripts/domain_report.py"), str(ws)],
                               capture_output=True, text=True)
            self.assertIn('"proven": 1', r.stdout, r.stderr)
            rows = {x["proxy"]: x for x in csv.DictReader((ws / "domain/functional-test-report.csv").open())}
            self.assertEqual(rows["x"]["gaps"], "none")
            self.assertIn("route not built", rows["y"]["gaps"])
            (m / "FLOW_CARD.md").write_text("Status: draft\nApprove by setting `Status: approved`, your name and the date\n")
            subprocess.run([sys.executable, str(ROOT / "skills/osb-camel-agent-kit/skills/osb-camelk-route/scripts/domain_report.py"), str(ws)], capture_output=True)
            rows = {x["proxy"]: x for x in csv.DictReader((ws / "domain/functional-test-report.csv").open())}
            self.assertEqual(rows["x"]["card"], "draft", "the instruction sentence is not an approval")


if __name__ == "__main__":
    unittest.main()


class SynthFromSchemaTests(unittest.TestCase):
    """Synthetic messages without an AI: from an nXSD (JSON) schema, scenario values applied, K9 closed."""
    SK = ROOT / "skills/osb-camel-agent-kit/skills/osb-camelk-route/scripts"
    XSD = ('<?xml version="1.0"?><xsd:schema xmlns:xsd="http://www.w3.org/2001/XMLSchema" '
           'xmlns:nxsd="http://xmlns.oracle.com/pcbpel/nxsd" nxsd:version="JSON"><xsd:element name="Root-Element">'
           '<xsd:complexType><xsd:sequence><xsd:element name="data"><xsd:complexType><xsd:sequence>'
           '<xsd:element name="flagA" type="xsd:boolean"/><xsd:element name="n" type="xsd:long"/>'
           '</xsd:sequence></xsd:complexType></xsd:element></xsd:sequence></xsd:complexType></xsd:element></xsd:schema>')

    def test_builds_cases_for_uncovered_rows(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "prj").mkdir()
            (d / "prj/x-nxsd.xsd").write_text(self.XSD)
            pack = {"proxy": "x", "entry": {"payload_format": "json", "nxsd": "x-nxsd"}, "scenario_dims": ["data.flagA"],
                    "branches": [], "outputs": [{"name": "q", "destination": "jndi.q"}, {"name": "err", "destination": "jndi.e", "on": "error"}],
                    "scenario_mapping": [{"scenario": "flagA=true", "outputs": ["q"]}, {"scenario": "flagA!=true", "outputs": []}],
                    "backends": [], "errors": [], "logs": [], "open_questions": []}
            (d / "res").mkdir()
            (d / "res/research.json").write_text(json.dumps(pack))
            run = lambda *a: subprocess.run([sys.executable, *map(str, a)], capture_output=True, text=True)  # noqa: E731
            run(self.SK / "scaffold_camelk.py", d / "res", "-o", d / "mod", "--project", "p")
            r = run(self.SK / "synth_from_schema.py", d / "mod", d / "prj", "--research", d / "res/research.json")
            self.assertIn('"written": 2', r.stdout, r.stderr)
            bodies = sorted(json.loads(p.read_text())["data"]["flagA"] for p in (d / "mod").rglob("input.payload"))
            self.assertEqual(bodies, [False, True])
            run(self.SK / "check_camelk.py", d / "mod", "--no-surefire")
            self.assertTrue(json.loads((d / "mod/GATES.json").read_text())["gates"]["K9_scenarios_covered"]["ok"])


if __name__ == "__main__":
    unittest.main()


class ScenarioKeyNormalisationTests(unittest.TestCase):
    """research keys with a path ('data.hasX=true') match Splunk cases labelled with the field name ('hasX=true')."""

    def test_path_keys_match_short_case_keys(self):
        sk = ROOT / "skills/osb-camel-agent-kit/skills/osb-camelk-route/scripts"
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "res").mkdir()
            (d / "res/research.json").write_text(json.dumps({
                "proxy": "x", "entry": {"payload_format": "json"}, "scenario_dims": ["data.hasA"], "branches": [],
                "outputs": [{"name": "q", "destination": "jndi.q"}, {"name": "e", "destination": "jndi.e", "on": "error"}],
                "scenario_mapping": [{"scenario": "data.hasA=true", "outputs": ["q"]}, {"scenario": "data.hasA!=true", "outputs": []}],
                "backends": [], "errors": [], "logs": [], "open_questions": []}))
            subprocess.run([sys.executable, str(sk / "scaffold_camelk.py"), str(d / "res"), "-o", str(d / "m"), "--project", "p"], capture_output=True)
            for v in ("true", "false"):
                c = d / f"m/src/test/resources/parity/p-x/s{v}/c1"
                c.mkdir(parents=True)
                (c / "input.payload").write_text("{}")
                (c.parent / "SCENARIO.txt").write_text(f"p/x|success|hdr_resource=R|hasA={v}\n")
            subprocess.run([sys.executable, str(sk / "check_camelk.py"), str(d / "m"), "--no-surefire"], capture_output=True)
            g = json.loads((d / "m/GATES.json").read_text())["gates"]["K9_scenarios_covered"]
            self.assertEqual(g["uncovered"], [])


if __name__ == "__main__":
    unittest.main()
