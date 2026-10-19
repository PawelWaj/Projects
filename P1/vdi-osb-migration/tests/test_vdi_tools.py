"""Tests for the VDI workflow tools. Run from the repo root: python3 -m unittest discover -s vdi-osb-migration/tests -v"""
import csv
import json
import re
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
            # a scenario field path the messages do not have (research named the wrong path) is flagged, not built
            fl = Path(d) / "flows.csv"
            fl.write_text("flow,domain,dims\na-prj/a,a,hdr_resource;body:data.notThere\n", encoding="utf-8")
            r = subprocess.run([sys.executable, str(BIN / "batch_task1.py"), str(f), "-o", str(Path(d) / "out2"), "--flows", str(fl)],
                               capture_output=True, text=True, env=dict(os.environ, MASK_KEY="k"))
            self.assertEqual(r.returncode, 1, r.stdout)
            self.assertIn("scenario field body:data.notThere found in none of", r.stdout)


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

    def test_annotated_business_service_is_one_output_and_props_are_clean(self):
        """research names a JMS business service 'svc-a (BS)' next to the output keyed 'svc-a': one destination, not two;
        notes in brackets never reach application.properties (K10), a backend that repeats an output fails K11."""
        pack = json.loads(json.dumps(self.PACK))
        pack["entry"]["durable_subscription"] = "true (name auto-generated by container)"
        pack["outputs"][0]["business_service"] = "svc-a"
        pack["outputs"][0]["destination"] = "jndi.qA-real"
        pack["backends"][0] = {"name": "svc-a (BS)", "type": "JMS queue", "operation": "publish"}
        with tempfile.TemporaryDirectory() as d:
            res, mod = Path(d, "res"), Path(d, "mod")
            res.mkdir()
            (res / "research.json").write_text(json.dumps(pack), encoding="utf-8")
            r = subprocess.run([sys.executable, str(self.SK / "scaffold_camelk.py"), str(res), "-o", str(mod), "--project", "p-prj"],
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            cfg = json.loads((mod / "src/test/resources/flow-test.json").read_text())
            self.assertEqual(cfg["backends"], {}, "a JMS business service that writes an output is that output")
            props = (mod / "src/main/resources/application.properties").read_text()
            self.assertFalse([ln for ln in props.splitlines() if not ln.startswith("#") and "(" in ln], "no notes in values")
            self.assertIn("flow.input=amqp:queue:jndi.inTopic::px\n", props)
            subprocess.run([sys.executable, str(self.SK / "check_camelk.py"), str(mod), "--no-surefire"], capture_output=True)
            gates = json.loads((mod / "GATES.json").read_text())["gates"]
            self.assertTrue(gates["K11_single_destination"]["ok"])
            # what pi produced on the VDI: an extra backend for the same service and a note in a value
            (mod / "src/main/resources/application.properties").write_text(
                props + "backend.svc-a-bs=amqp:queue:svc-a (BS)\n")
            route = next(mod.rglob("*.camel.yaml"))
            route.write_text(route.read_text() + '\n# uri: "{{backend.not-defined}}"\n')
            subprocess.run([sys.executable, str(self.SK / "check_camelk.py"), str(mod), "--no-surefire"], capture_output=True)
            gates = json.loads((mod / "GATES.json").read_text())["gates"]
            self.assertFalse(gates["K10_properties_valid"]["ok"])
            self.assertIn("backend.svc-a-bs", json.dumps(gates["K10_properties_valid"]))
            self.assertFalse(gates["K11_single_destination"]["ok"])
            self.assertIn("svc-a", json.dumps(gates["K11_single_destination"]))

    def test_osb_conventions_no_action_path_local_properties_and_refresh(self):
        """A branch path without output is no action in OSB: no `when`, no id for K3. The correlation id is generated
        when OSB does (fn-bea:uuid); error headers come from the research; the selector becomes the subscription filter;
        env/local.properties maps the JNDI names for a local broker; one-way flows send InOnly; --refresh rewrites
        only the named infrastructure files; plan_queues.py derives the broker objects from env/local.properties."""
        pack = json.loads(json.dumps(self.PACK))
        pack["entry"]["selector"] = "(kind='x') AND (type='y')"
        pack["branches"][0]["paths"].append({"label": "false-default", "condition_plain": "flagA not true", "outputs": []})
        pack["outputs"][2]["headers"] = [{"name": "errorCode", "source": "$fault errorCode"}, {"name": "debugInfo", "source": "$fault location stage"},
                                         {"name": "traceId", "source": "$uuId"}, {"name": "resource", "source": "inbound user-header resource"}]
        with tempfile.TemporaryDirectory() as d:
            res, mod = Path(d, "res"), Path(d, "mod")
            res.mkdir()
            (res / "research.json").write_text(json.dumps(pack), encoding="utf-8")
            r = subprocess.run([sys.executable, str(self.SK / "scaffold_camelk.py"), str(res), "-o", str(mod), "--project", "p-prj"],
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            route = (mod / "src/main/resources/routes/px.camel.yaml").read_text()
            self.assertNotIn("id: branch-a-check-false-default", route, "no `when` for a path without action")
            self.assertIn("no output in OSB = no action", route)
            self.assertIn("id: branch-a-check-a", route)
            self.assertIn('simple: "${header.traceId} ?: ${uuid(random)}"', route)
            self.assertIn("name: osbStage", route)
            self.assertIn('simple: "${exchangeProperty.osbStage}"', route)
            self.assertIn('simple: "${exception.class.simpleName}"', route)
            self.assertIn("# resource: inbound header", route)
            self.assertIn("${exchangeProperty.<field>}", route)
            meta = json.loads((mod / ".scaffold.json").read_text())
            self.assertNotIn("branch-a-check-false-default", meta["route_ids"])
            props = (mod / "src/main/resources/application.properties").read_text()
            self.assertIn("flow.input.selector=(kind='x') AND (type='y')", props)
            self.assertIn("flow.input=amqp:queue:jndi.inTopic::px", props)
            local = (mod / "env/local.properties").read_text()
            values = [ln for ln in local.splitlines() if ln and not ln.startswith("#")]
            self.assertIn("flow.input=amqp:queue:inTopic::px", values)
            self.assertIn("out.svc-a=amqp:queue:qA", values)
            self.assertIn("camel.beans.amqpConnectionFactory.password={{env:BROKER_PASSWORD:}}", props, "connection from the platform env, no value")
            self.assertFalse([v for v in values if v.startswith("camel.")], "the local file overrides endpoints only")
            self.assertFalse([v for v in values if "jndi." in v], "local addresses carry no JNDI prefix")
            test = next(mod.rglob("FlowParityTest.java")).read_text()
            self.assertIn("ExchangePattern.InOnly", test)
            cfg = json.loads((mod / "src/test/resources/flow-test.json").read_text())
            self.assertTrue(cfg["correlation_generated"])
            self.assertEqual(cfg["scenario_fields"], ["flagA", "flagB"])
            bean = next(mod.rglob("OsbJson.java")).read_text()
            self.assertIn("exchange.setProperty(", bean)
            self.assertNotIn("setHeader(", bean)
            pom = (mod / "pom.xml").read_text()
            self.assertIn("camel-amqp", pom)
            self.assertIn("<id>run-local</id>", pom)
            subprocess.run([sys.executable, str(self.SK / "check_camelk.py"), str(mod), "--no-surefire"], capture_output=True)
            gates = json.loads((mod / "GATES.json").read_text())["gates"]
            self.assertTrue(gates["K10_properties_valid"]["ok"], gates["K10_properties_valid"])
            self.assertTrue(gates["K3_route_ids"]["ok"])
            # the broker objects a local Artemis needs, from env/local.properties
            plan = subprocess.run([sys.executable, str(ROOT / "skills/osb-camel-agent-kit/broker/plan_queues.py"), str(mod)],
                                  capture_output=True, text=True)
            self.assertEqual(plan.returncode, 0, plan.stderr)
            objs = {o["name"]: o for o in json.loads(plan.stdout)}
            self.assertEqual(objs["px"]["address"], "inTopic")
            self.assertEqual(objs["px"]["routing"], "multicast")
            self.assertEqual(objs["px"]["filter"], "(kind='x') AND (type='y')")
            self.assertEqual(objs["qA"]["routing"], "anycast")
            self.assertEqual(set(objs), {"px", "qA", "qB", "qErr"})
            # --refresh pom rewrites the pom only; the route and the local properties stay
            (mod / "pom.xml").write_text("x")
            (mod / "env/local.properties").write_text("y")
            subprocess.run([sys.executable, str(self.SK / "scaffold_camelk.py"), str(res), "-o", str(mod), "--project", "p-prj", "--refresh", "pom"],
                           capture_output=True, text=True)
            self.assertIn("camel-amqp", (mod / "pom.xml").read_text())
            self.assertEqual((mod / "env/local.properties").read_text(), "y")

    def test_assemble_flat_merges_flows_of_a_project(self):
        """Two proxies of one project -> one flat folder: one route file with prefixed placeholders and unique ids,
        <Flow>Transformer/<Flow>TransformerTest, kamelet endpoints, every test knows the other flow's endpoints."""
        with tempfile.TemporaryDirectory() as d:
            ws = Path(d)
            for px in ("first-flow", "second-flow"):
                pack = json.loads(json.dumps(self.PACK)); pack["proxy"] = px
                res = ws / "research" / px; res.mkdir(parents=True)
                (res / "research.json").write_text(json.dumps(pack), encoding="utf-8")
                r = subprocess.run([sys.executable, str(self.SK / "scaffold_camelk.py"), str(res), "-o", str(ws / "modules/p-prj" / px),
                                    "--project", "p-prj"], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr)
            r = subprocess.run([sys.executable, str(self.SK / "assemble_flat.py"), str(ws), "--app", "the-app"], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(json.loads(r.stdout)["flows"], 2)
            root = ws / "delivery/the-app"
            self.assertTrue((root / "Common-setup/osb-jms-source.kamelet.yaml").is_file())
            flat = root / "p-prj"
            names = sorted(p.name for p in flat.iterdir() if p.is_file())
            for n in ("p-route.yaml", "FirstFlowTransformer.java", "FirstFlowTransformerTest.java", "SecondFlowTransformer.java",
                      "SecondFlowTransformerTest.java", "application.properties", "pom.xml"):
                self.assertIn(n, names)
            route = (flat / "p-route.yaml").read_text()
            self.assertIn('uri: "{{first-flow.flow.input}}"', route)
            self.assertIn('uri: "{{second-flow.out.svc-a}}"', route)
            self.assertIn("beanType: osb.pprj.FirstFlowTransformer", route)
            ids = re.findall(r"^\s*(?:-\s+)?id:\s*(\S+)\s*$", route, re.M)
            self.assertEqual(len(ids), len(set(ids)), "ids unique across flows")
            props = (flat / "application.properties").read_text()
            self.assertIn("first-flow.flow.input=kamelet:osb-jms-source?destination=queue:jndi.inTopic::first-flow", props)
            self.assertIn("second-flow.out.svc-a=kamelet:osb-jms-sink?destination=queue:jndi.qA", props)
            self.assertIn("camel.main.routes-include-pattern=classpath:p-route.yaml", props)
            test = (flat / "FirstFlowTransformerTest.java").read_text()
            self.assertIn("package osb.pprj;", test)
            self.assertIn("class FirstFlowTransformerTest", test)
            self.assertIn('"first-flow.flow.input=direct:in-first-flow"', test)
            self.assertIn('"second-flow.flow.input=direct:in-second-flow"', test)
            self.assertIn('@Produce("direct:in-first-flow")', test)
            self.assertIn('"src/test/resources/first-flow/', test)
            cfg = json.loads((flat / "src/test/resources/first-flow/flow-test.json").read_text())
            self.assertTrue(all(v.startswith("mock:first-flow-out-") for k, v in cfg["outputs"].items() if v != "reply"))
            local = (flat / "src/env/local.properties").read_text()
            self.assertIn("first-flow.flow.input=kamelet:osb-jms-source?destination=queue:inTopic::first-flow", local)
            plan = subprocess.run([sys.executable, str(ROOT / "skills/osb-camel-agent-kit/broker/plan_queues.py"), str(flat)],
                                  capture_output=True, text=True)
            self.assertEqual({o["name"] for o in json.loads(plan.stdout)}, {"first-flow", "second-flow", "qA", "qB", "qErr"})

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

    def test_header_scenario_field(self):
        """A branch on a message header (research 'header.resource') is labelled hdr_resource, as Splunk labels it."""
        pack = {**self.PACK, "scenario_dims": ["header.resource"], "entry": {"transport": "jms", "payload_format": "json"},
                "scenario_mapping": [{"scenario": "header.resource=Bulk A", "outputs": ["err"]},
                                     {"scenario": "resource=Bulk B", "outputs": []}]}
        with tempfile.TemporaryDirectory() as d:
            res, mod = Path(d, "res"), Path(d, "mod")
            res.mkdir()
            (res / "research.json").write_text(json.dumps(pack))
            subprocess.run([sys.executable, str(self.SK / "scaffold_camelk.py"), str(res), "-o", str(mod), "--project", "s-prj"], capture_output=True)
            cfg = json.loads((mod / "src/test/resources/flow-test.json").read_text())
            self.assertEqual([m["scenario"] for m in cfg["scenario_mapping"]], ["hdr_resource=Bulk A", "hdr_resource=Bulk B"])
            self.assertNotIn('"header.resource"', next(mod.rglob("OsbJson.java")).read_text(), "a header is no payload path")

    def test_stale_synthetic_removed(self):
        """A synthetic case written for an old mapping row is removed (and unfrozen) when the mapping changes."""
        with tempfile.TemporaryDirectory() as d:
            res, mod = Path(d, "res"), Path(d, "mod")
            res.mkdir()
            (res / "research.json").write_text(json.dumps(self.PACK))
            run = lambda *a: subprocess.run([sys.executable, *map(str, a)], capture_output=True, text=True)  # noqa: E731
            run(self.SK / "scaffold_camelk.py", res, "-o", mod, "--project", "s-prj")
            old = mod / "src/test/resources/parity/s-prj-get-status-synthetic/resource-old/case1"
            old.mkdir(parents=True)
            (old.parent / "SCENARIO.txt").write_text("s-prj/get-status|success|resource=Old\n")
            (old / "input.payload").write_text("{}")
            run(self.SK / "scaffold_camelk.py", res, "-o", mod, "--project", "s-prj", "--freeze-synthetic")
            r = run(self.SK / "synth_from_schema.py", mod, d, "--research", res / "research.json")
            self.assertIn("removed_stale_synthetic", r.stdout, r.stderr)
            self.assertFalse(old.exists())
            self.assertFalse(any("resource-old" in k for k in json.loads((mod / ".scaffold.json").read_text())["generated"]))

    def test_short_output_names_and_default_row(self):
        """Table outputs written short ('bulk-register') resolve to the output key; 'x=<other>' = OSB default branch."""
        pack = {**self.PACK, "scenario_dims": ["header.resource"], "entry": {"transport": "jms", "payload_format": "json"},
                "outputs": [{"name": "a", "business_service": "business-service-bulk-register-bix"},
                            {"name": "b", "business_service": "business-service-bulk-terminate-bix"},
                            {"name": "e", "business_service": "business-service-bulk-register-error-queue-bix", "on": "error handler"}],
                "scenario_mapping": [{"scenario": "resource=Reg", "outputs": ["bulk-register"]},
                                     {"scenario": "resource=Term", "outputs": ["bulk-terminate"]},
                                     {"scenario": "resource=<other>", "outputs": ["bulk-terminate"]}]}
        with tempfile.TemporaryDirectory() as d:
            res, mod = Path(d, "res"), Path(d, "mod")
            res.mkdir()
            (res / "research.json").write_text(json.dumps(pack))
            r = subprocess.run([sys.executable, str(self.SK / "scaffold_camelk.py"), str(res), "-o", str(mod), "--project", "s-prj"],
                               capture_output=True, text=True)
            self.assertNotIn("WARNING", r.stdout)
            cfg = json.loads((mod / "src/test/resources/flow-test.json").read_text())
            self.assertEqual([(m["scenario"], m["outputs"]) for m in cfg["scenario_mapping"]],
                             [("hdr_resource=Reg", ["business-service-bulk-register-bix"]),
                              ("hdr_resource=Term", ["business-service-bulk-terminate-bix"]),
                              ("hdr_resource!=Reg|hdr_resource!=Term", ["business-service-bulk-terminate-bix"])])

    def test_generated_fields_by_name_and_where_present(self):
        """OSB time stamps (any format, masked or not) count as generated where they appear; copied values do not."""
        sys.path.insert(0, str(self.SK))
        import scaffold_camelk
        with tempfile.TemporaryDirectory() as d:
            for i, (inp, out) in enumerate([({"data": {"a": 1, "birthDate": "x1"}}, {"a": 1, "birthDate": "x1", "publishDate": "19/10/2026", "timestamp": 12345}),
                                            ({"data": {"a": 2, "birthDate": "x2"}}, {"a": 2, "birthDate": "x2", "publishDate": "20/10/2026", "timestamp": 1}),
                                            ({"body": {"a": 3}}, {"body": {"a": 3}})]):
                c = Path(d, f"s/c{i}")
                c.mkdir(parents=True)
                (c / "input.payload").write_text(json.dumps(inp))
                (c / "expected-output.json").write_text(json.dumps(out))
            self.assertEqual(scaffold_camelk.generated_fields(Path(d)), ["publishDate", "timestamp"])

    def test_selector_fill_and_filter(self):
        """Broker test: properties OSB does not log get a value the selector allows; a resource it excludes stays filtered."""
        sys.path.insert(0, str(ROOT / "skills/osb-camel-agent-kit/broker"))
        import e2e_check as e
        sel = "(resource='A' OR resource='B') AND (eventType='created' OR eventType='update-approved')"
        self.assertEqual(e.fill_for_selector(sel, {"resource": "B"}), {"eventType": "created"})
        self.assertTrue(e.passes(sel, {"resource": "B", "eventType": "created"}))
        self.assertFalse(e.passes(sel, {"resource": "C", **e.fill_for_selector(sel, {"resource": "C"})}))
        self.assertIsNone(e.evaluate("a LIKE 'x%'", {}))

    def test_review_note_reads_broker_run(self):
        """review_note.py turns the e2e_local.sh output into numbers and review points."""
        sys.path.insert(0, str(self.SK))
        import review_note
        ev = review_note.e2e("   f c1 -> expect q: sent 1 message(s) to topic://t (+eventType=created, kind=x for the selector) with properties\n"
                             "   f c2 -> expect (filtered by the subscription selector): sent 1 message(s)\n"
                             "input of f: subscription queue f: 3 expected past the selector, 3 arrived; selector: x\n"
                             "f                      outQ          2        1  DIFF\nRESULT: 1 queue(s) differ\n")
        self.assertEqual(ev["filled"], {"eventType=created", "kind=x"})
        self.assertEqual(ev["filtered"], [("f", "c2")])
        self.assertEqual(ev["rows"], [("f", "outQ", "2", "1", "DIFF")])
        self.assertEqual(ev["inputs"], [("f", "f", "3", "3")])

    def test_body_chain_per_output(self):
        """Output format per flow comes from the pipeline: nXSD + XQuery per branch = XML, error path = original."""
        sys.path.insert(0, str(self.SK))
        import body_chain
        d = body_chain.walk(self.SK.parent / "tests/fixtures/branch-xquery.pipeline")
        got = {(r["service"], r["format"], tuple(c.get("resource") or c.get("op") for c in r["chain"])) for r in d["outputs"]}
        self.assertEqual(got, {("x-register", "xml", ("nxsd", "x-register")), ("x-terminate", "xml", ("nxsd", "x-terminate"))})
        self.assertEqual([(r["service"], r["format"], r["headers"]) for r in d["error_outputs"]],
                         [("x-error-queue", "native", ["errorCode", "eventType"])])
        self.assertEqual(d["unknown_tags"], [])

    def test_assemble_jbang_no_pom_xml_chain(self):
        """No-pom delivery: route built from the OSB body chain (nXSD + the flow's own .xqy per branch), Artemis kamelets,
        JBang test file, transformation files copied; no pom anywhere."""
        F = self.SK.parent / "tests/fixtures/jbang"
        with tempfile.TemporaryDirectory() as d:
            ws = Path(d)
            (ws / "research/x-prj/x").mkdir(parents=True)
            shutil.copy(F / "research/research.json", ws / "research/x-prj/x/research.json")
            subprocess.run([sys.executable, str(self.SK / "scaffold_camelk.py"), str(ws / "research/x-prj/x"), "-o",
                            str(ws / "modules/x-prj/x"), "--project", "x-prj"], capture_output=True)
            shutil.copytree(F / "parity", ws / "modules/x-prj/x/src/test/resources/parity", dirs_exist_ok=True)
            r = subprocess.run([sys.executable, str(self.SK / "assemble_jbang.py"), str(ws), "--osb-app", str(F / "osbapp"),
                                "--app", "a", "--projects", "x-prj"], capture_output=True, text=True)
            self.assertIn('"flows": 1', r.stdout, r.stderr)
            p = ws / "delivery/a/x-prj"
            route = (p / "x-route.yaml").read_text()
            self.assertIn("transformations/x-register.xqy", route)
            self.assertIn("transformations/x-terminate.xqy", route)
            self.assertIn("osb.common.OsbNxsd", route)
            self.assertIn('${exchangeProperty.request}', route)
            self.assertIn("selector=RAW(", (p / "application.properties").read_text())
            self.assertTrue((p / "test/XTest.java").is_file() and (p / "transformations/x-nxsd.xsd").is_file())
            self.assertFalse(list((ws / "delivery").rglob("pom.xml")), "no pom in the delivery")
            self.assertIn("| x-register | xml |", (p / "docs/x/BODY_CHAIN.md").read_text())

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
