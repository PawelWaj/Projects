"""Tests for the VDI workflow tools. Run from the repo root: python3 -m unittest discover -s vdi-osb-migration/tests -v"""
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
