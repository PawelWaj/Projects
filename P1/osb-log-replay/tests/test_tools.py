"""Unit tests for the osb-log-replay tools. Run: python3 -m unittest discover -s tests -v (stdlib only)."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import osb_log_signatures as sigmod  # noqa: E402
import osb_log_traces as trmod  # noqa: E402
import replay_runner as rr  # noqa: E402
import spl_from_signatures as spl  # noqa: E402

SAMPLES = ROOT / "samples"
CONFIG = ROOT / "replay-config.json"


def run(*args):
    return subprocess.run([sys.executable, *map(str, args)], capture_output=True, text=True, check=True)


class SignatureTests(unittest.TestCase):
    def test_split_respects_quotes_and_parentheses(self):
        parts = sigmod.split_top_level('"a, b", fn:data($x/y[@n="1,2"]), \'it\'\'s\'')
        self.assertEqual(parts, ['"a, b"', 'fn:data($x/y[@n="1,2"])', "'it''s'"])

    def test_literal_unescape(self):
        self.assertEqual(sigmod.literal_value("'it''s'"), "it's")

    def test_group_names(self):
        used = {}
        self.assertEqual(sigmod.group_name('fn:data($inbound/a/*:user-header[@name="resource"]/@value)', used), "hdr_resource")
        self.assertEqual(sigmod.group_name("$body//*:resourceId/text()", used), "body_resourceId")
        self.assertEqual(sigmod.group_name("$body", used), "body")
        self.assertEqual(sigmod.group_name("fn-bea:serialize($fault)", used), "fault")
        self.assertEqual(sigmod.group_name("$uuId", used), "uuId")
        self.assertEqual(sigmod.group_name("$uuId", used), "uuId_2")

    def test_signature_matches_its_own_output(self):
        sig = sigmod.build_signature('fn:concat("Request Received with TraceID - ",$uuId," ::",$body)')
        import re
        m = re.compile(sig["regex"], re.S).search("Request Received with TraceID - abc-1 ::{\n \"a\": 1\n}")
        self.assertEqual(m.group("uuId"), "abc-1")
        self.assertIn('"a": 1', m.group("body"))
        self.assertEqual(sig["roles"]["correlation"], ["uuId"])
        self.assertEqual(sig["roles"]["payload"], ["body"])

    def test_warnings(self):
        sig = sigmod.build_signature('fn:concat("x",$a,$b)')
        self.assertTrue(any("ambiguous" in w for w in sig["warnings"]))
        self.assertTrue(any("no correlation" in w for w in sig["warnings"]))

    def test_sample_export(self):
        with tempfile.TemporaryDirectory() as d:
            run(ROOT / "tools/osb_log_signatures.py", SAMPLES, "-o", Path(d) / "s.json")
            sigs = json.loads((Path(d) / "s.json").read_text())["signatures"]
        self.assertEqual(len(sigs), 3)
        self.assertEqual({s["pipeline_type"] for s in sigs}, {"request", "error"})
        self.assertEqual(sum(1 for s in sigs if s["level"] == "debug"), 1)


class TraceTests(unittest.TestCase):
    def test_weblogic_envelope(self):
        raw = "####<Oct 6> <Info> <OSB Pipeline> <h> <s> <t> <u> <> <x> <1791270902101> <[x] > <BEA-000000> < [st, p, null, REQUEST] hello world>"
        msg, meta = trmod.osb_message(raw)
        self.assertEqual((msg, meta["bea"], meta["format"]), ("hello world", "BEA-000000", "weblogic"))

    def test_odl_envelope(self):
        raw = ("[2026-10-08T11:59:16.339+03:00] [osb_server1] [NOTIFICATION] [] [oracle.osb.logging.pipeline] "
               "[tid: [ACTIVE].ExecuteThread: '97' for queue: 'x'] [userId: <anonymous>] [ecid: abc-1,0] [FlowId: F1]  "
               "[node, request-1, stage-1, REQUEST] Request Received ::{\"a\":1}")
        msg, meta = trmod.osb_message(raw)
        self.assertEqual(msg, 'Request Received ::{"a":1}')
        self.assertEqual((meta["format"], meta["level"], meta["ecid"], meta["flow_id"]), ("odl", "NOTIFICATION", "abc-1", "F1"))

    def test_json_field_masking_keeps_json_valid(self):
        m = trmod.Masker(trmod.DEFAULT_MASKS, trmod.DEFAULT_JSON_KEYS + ["branchNameArb"])
        src = ('{"name":{"firstName":"Jane","surName":"Example","nameEnglish":"JANE EXAMPLE"},"nin":1000000001,'
               '"birthDate":{"gregorian":"1999-05-17T00:00:00.000Z","hijiri":"1420-01-30"},"branchNameArb":"x y",'
               '"amount":0.00,"keep":"visible"}')
        out = m(src)
        doc = json.loads(out)
        self.assertNotIn("Jane", out)
        self.assertNotIn("JANE EXAMPLE", out)
        self.assertNotIn("1000000001", out)
        self.assertNotIn("x y", out)
        g = doc["birthDate"]["gregorian"]
        self.assertRegex(g, r"^\d{4}-\d{2}-\d{2}T00:00:00\.000Z$")
        self.assertNotEqual(g[:10], "1999-05-17")
        self.assertEqual(len(str(doc["nin"])), 10)
        self.assertEqual(doc["keep"], "visible")
        self.assertIn('"amount":0.00', out)                      # untouched fields keep their exact text
        self.assertEqual(m(src), out)                             # deterministic

    def test_odl_sample_end_to_end(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            run(ROOT / "tools/osb_log_signatures.py", SAMPLES, "-o", d / "s.json")
            run(ROOT / "tools/osb_log_traces.py", d / "s.json", SAMPLES / "osb-odl-sample.log", "-o", d / "t", "--unkeyed")
            cov = json.loads((d / "t/coverage.json").read_text())
            traces = [json.loads(line) for line in (d / "t/traces.jsonl").read_text().splitlines()]
        self.assertEqual(cov["formats"], {"odl": 3})
        self.assertEqual(cov["events_matched"], 3)
        self.assertEqual(cov["traces"], 2)
        body = [t for t in traces if t["outcome"] == "success"][0]["events"][0]["fields"]["body"]
        self.assertNotIn("Jane", body)
        self.assertNotIn("jane@example.org", body)
        self.assertNotEqual(json.loads(body)["data"]["customer"]["birthDate"]["gregorian"][:10], "1999-05-17")
        err = [t for t in traces if t["outcome"] == "error"][0]
        self.assertEqual(err["fault_code"], "BEA-382000")

    def test_masking_is_deterministic_and_spares_uuids(self):
        m = trmod.Masker(trmod.DEFAULT_MASKS)
        a = m("id 1234567890 in /c/1234567890/x uuid 7f3c2a10-1111-4a2b-9c01-000000000001 mail a.b@c.com")
        self.assertNotIn("1234567890", a)
        self.assertIn("7f3c2a10-1111-4a2b-9c01-000000000001", a)
        self.assertNotIn("a.b@c.com", a)
        self.assertEqual(m("1234567890"), m("1234567890"))
        self.assertEqual(len(m("1234567890")), 10)

    def test_sample_pipeline_to_scenarios(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            run(ROOT / "tools/osb_log_signatures.py", SAMPLES, "-o", d / "s.json")
            run(ROOT / "tools/osb_log_traces.py", d / "s.json", SAMPLES / "osb-weblogic-sample.log", "-o", d / "t", "--unkeyed")
            cov = json.loads((d / "t/coverage.json").read_text())
            scen = json.loads((d / "t/scenarios.json").read_text())
            traces = [json.loads(line) for line in (d / "t/traces.jsonl").read_text().splitlines()]
        self.assertEqual(cov["events_read"], 8)
        self.assertEqual(cov["events_unmatched"], 1)          # the WebLogic RUNNING line is not an OSB log action
        self.assertEqual(cov["traces"], 4)
        self.assertEqual(cov["traces_without_payload"], 1)    # debug line missing for trace 4
        self.assertTrue(any("errorCode=BEA-382000" in s["scenario"] for s in scen))
        multi = [t for t in traces if t["correlation"].endswith("0002")][0]
        self.assertIn('"referenceNo": "REF-0002"', multi["events"][0]["fields"]["body"])
        self.assertTrue(all("Cancel Order" in t["branch"].get("hdr_resource", "") for t in [multi]))


class FixtureTests(unittest.TestCase):
    def test_fixtures_and_manifest(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            run(ROOT / "tools/osb_log_signatures.py", SAMPLES, "-o", d / "s.json")
            run(ROOT / "tools/osb_log_traces.py", d / "s.json", SAMPLES / "osb-weblogic-sample.log", "-o", d / "t", "--unkeyed")
            out = run(ROOT / "tools/fixtures_from_traces.py", d / "t/traces.jsonl", CONFIG, "-o", d / "fx").stdout
            inputs = list((d / "fx/parity").rglob("input.payload"))
            manifest = (d / "fx/golden/MANIFEST.csv").read_text().splitlines()
            err = [p.parent for p in inputs if json.loads((p.parent / "expected.json").read_text())["outcome"] == "error"]
            headers = json.loads((err[0] / "headers.json").read_text())
            expected = json.loads((err[0] / "expected.json").read_text())
        self.assertEqual(len(inputs), 3)                      # 4 traces, one without payload is skipped
        self.assertIn("SKIPPED", out)
        self.assertEqual(len(manifest), 1 + 3 * 3)
        self.assertTrue(all(",osb-recording," in row for row in manifest[1:]))
        self.assertEqual(headers["resource"], "Create Order")
        self.assertIn("traceId", headers)
        self.assertEqual(expected["destination"], "orderEventErrorQueue")
        self.assertIn("errorCode", expected["expected_headers"])


class FakeBroker:
    """Plays the flow under test: routes each sent message by a rule function."""

    def __init__(self, rule):
        self.rule, self.inbox = rule, []

    def subscribe(self, destination, dtype):
        pass

    def send(self, destination, dtype, body, headers):
        out = self.rule(body, headers)
        if out:
            self.inbox.append(out)

    def receive(self, timeout):
        return self.inbox.pop(0) if self.inbox else None


class ReplayTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = Path(self.tmp.name)
        run(ROOT / "tools/osb_log_signatures.py", SAMPLES, "-o", d / "s.json")
        run(ROOT / "tools/osb_log_traces.py", d / "s.json", SAMPLES / "osb-weblogic-sample.log", "-o", d / "t", "--unkeyed")
        run(ROOT / "tools/fixtures_from_traces.py", d / "t/traces.jsonl", CONFIG, "-o", d / "fx")
        self.cfg = json.loads(CONFIG.read_text())
        self.flow = "order-event-prj/order-event"
        self.fc = dict(self.cfg["flows"][self.flow], timeout_s=0.2)
        self.fixtures = rr.find_fixtures(d / "fx", self.flow)

    def tearDown(self):
        self.tmp.cleanup()

    @staticmethod
    def correct_flow(body, headers):
        if headers.get("eventType") != "updated" or headers.get("resource") not in ("Create Order", "Cancel Order"):
            return None                                       # dropped by the subscription filter
        try:
            json.loads(body)
            return ("/queue/InboundOrderEventQueue", {"traceId": headers["traceId"]}, body)
        except ValueError:
            return ("orderEventErrorQueue", {k: "x" for k in ("errorCode", "errorMessage", "resource", "eventType")}
                    | {"traceId": headers["traceId"]}, body)

    def test_correct_flow_passes_all(self):
        res = rr.run_flow(FakeBroker(self.correct_flow), self.flow, self.fc, self.fixtures, negative=True)
        self.assertEqual(len(res), 3 + 2)
        self.assertTrue(all(r["status"] == "PASS" for r in res), res)

    def test_wrong_outcome_and_missing_headers_fail(self):
        def broken(body, headers):                            # sends everything to the error queue without error headers
            return ("orderEventErrorQueue", {"traceId": headers["traceId"]}, body)
        res = rr.run_flow(FakeBroker(broken), self.flow, self.fc, self.fixtures, negative=True)
        probs = " ".join(p for r in res for p in r["problems"])
        self.assertIn("outcome error, expected success", probs)
        self.assertIn("missing headers", probs)
        self.assertIn("was delivered", probs)                 # negative cases leak through

    def test_golden_body_comparison(self):
        ok = [f for f in self.fixtures if json.loads((f / "expected.json").read_text())["outcome"] == "success"][0]
        (ok / "expected-output.xml").write_text("<a><b>1</b></a>")
        def flow(body, headers):
            return ("InboundOrderEventQueue", {"traceId": headers["traceId"]}, "<a>\n  <b>2</b>\n</a>")
        res = rr.run_flow(FakeBroker(flow), self.flow, self.fc, [ok], negative=False)
        self.assertIn("body differs", " ".join(res[0]["problems"]))

    def test_junit(self):
        xml = rr.junit([{"flow": "f", "case": "c", "status": "FAIL", "problems": ["x <y>"], "seconds": 1}])
        self.assertIn('failures="1"', xml)
        self.assertIn("x &lt;y&gt;", xml)


class SplTests(unittest.TestCase):
    def test_pcre_conversion(self):
        self.assertEqual(spl.pcre('a(?P<x>.*?)"b'), 'a(?<x>.*?)\\"b')


if __name__ == "__main__":
    unittest.main()


class MaskingV2Tests(unittest.TestCase):
    SRC = ('{"name":"update-approved","data":{"mhrsdLaborerRequest":{"name":{"firstName":"\u0633\u0627\u0645\u064a",'
           '"surName":"\u0645\u062b\u0627\u0644","nameEnglish":"TEST PERSON"},"establishmentNameArb":"\u0645\u0624\u0633\u0633\u0629",'
           '"remarks":"free text about a person","iban":"SA0380000000608010167519","nin":1555555555,'
           '"birthDate":{"gregorian":"1995-03-15T00:00:00.000Z","hijiri":"1415-10-14","entryFormat":"GREGORIAN"},'
           '"joiningDate":{"gregorian":"2021-01-01T00:00:00.000Z"},"engagementId":1222222222,"wage":5000}},'
           '"resource":"Contributory Wage","uuid":"00000000-1111-4222-8333-444444444444"}')

    def masker(self, key=b"k1"):
        return trmod.Masker(trmod.DEFAULT_MASKS, trmod.DEFAULT_JSON_KEYS, key=key)

    def test_keyed_deterministic_and_key_dependent(self):
        a, b, c = self.masker()(self.SRC), self.masker()(self.SRC), self.masker(b"k2")(self.SRC)
        self.assertEqual(a, b)
        self.assertNotEqual(a, c)

    def test_pattern_keys_and_event_name_kept(self):
        out = self.masker()(self.SRC)
        doc = json.loads(out)
        req = doc["data"]["mhrsdLaborerRequest"]
        self.assertEqual(doc["name"], "update-approved")                    # event type is not a person name
        self.assertEqual(doc["resource"], "Contributory Wage")
        for v in (req["name"]["firstName"], req["name"]["surName"], req["name"]["nameEnglish"],
                  req["establishmentNameArb"], req["remarks"], req["iban"]):
            self.assertTrue(v.startswith("masked_"), v)
        self.assertNotRegex(out, r"[\u0600-\u06FF]")                    # no Arabic script left
        self.assertNotIn("SA0380000000608010167519", out)
        self.assertEqual(len(str(req["nin"])), 10)
        self.assertNotEqual(req["nin"], 1555555555)
        self.assertEqual(doc["uuid"], "00000000-1111-4222-8333-444444444444")
        self.assertEqual(req["wage"], 5000)

    def test_dates_shift_but_keep_format_and_band(self):
        import datetime
        req = json.loads(self.masker()(self.SRC))["data"]["mhrsdLaborerRequest"]
        g = req["birthDate"]["gregorian"]
        self.assertRegex(g, r"^\d{4}-\d{2}-\d{2}T00:00:00\.000Z$")
        delta = abs((datetime.date.fromisoformat(g[:10]) - datetime.date(1995, 3, 15)).days)
        self.assertTrue(0 < delta <= 183, delta)
        self.assertRegex(req["birthDate"]["hijiri"], r"^14\d{2}-\d{2}-\d{2}$")
        self.assertEqual(req["birthDate"]["entryFormat"], "GREGORIAN")
        self.assertEqual(req["joiningDate"]["gregorian"], "2021-01-01T00:00:00.000Z")   # not a personal date

    def test_xml_payload_masked(self):
        m = self.masker()
        out = m('<req xmlns:p="urn:x"><p:firstName>Jane</p:firstName><nin>1555555555</nin><amount>12.50</amount>'
                '<remarks>text</remarks></req>')
        self.assertNotIn("Jane", out)
        self.assertNotIn("1555555555", out)
        self.assertIn("<amount>12.50</amount>", out)
        self.assertRegex(out, r"<p:firstName>masked_[0-9a-f]{10}</p:firstName>")
        self.assertRegex(out, r"<nin>\d{10}</nin>")

    def test_cli_requires_key_or_unkeyed(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            run(ROOT / "tools/osb_log_signatures.py", SAMPLES, "-o", d / "s.json")
            env = {k: v for k, v in __import__("os").environ.items() if k != "MASK_KEY"}
            r = subprocess.run([sys.executable, str(ROOT / "tools/osb_log_traces.py"), str(d / "s.json"),
                                str(SAMPLES / "osb-odl-sample.log"), "-o", str(d / "t")], capture_output=True, text=True, env=env)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("MASK_KEY", r.stderr)
            env["MASK_KEY"] = "test-key"
            r = subprocess.run([sys.executable, str(ROOT / "tools/osb_log_traces.py"), str(d / "s.json"),
                                str(SAMPLES / "osb-odl-sample.log"), "-o", str(d / "t")], capture_output=True, text=True, env=env)
            self.assertEqual(r.returncode, 0, r.stderr)
            cov = json.loads((d / "t/coverage.json").read_text())
            self.assertTrue(cov["masking"]["keyed"])
            self.assertEqual(len(cov["masking"]["key_id"]), 8)
            # residue check passes on the masked output and fails on a planted leak
            r = run(ROOT / "tools/mask_residue_check.py", d / "t")
            self.assertIn("0 findings", r.stdout)
            (d / "t/leak.json").write_text('{"firstName":"\u0633\u0627\u0645\u064a","email":"x@real.sa"}', encoding="utf-8")
            r = subprocess.run([sys.executable, str(ROOT / "tools/mask_residue_check.py"), str(d / "t")], capture_output=True, text=True)
            self.assertEqual(r.returncode, 1)
            self.assertIn("arabic-script", r.stdout)
            self.assertIn("unmasked-email", r.stdout)
            self.assertNotIn("x@real.sa", r.stdout)                            # values are never printed


class AnonymizeLogsTests(unittest.TestCase):
    SAMPLE = SAMPLES / "splunk-export-synthetic.csv"

    def anonymize(self, d, *extra, key="test-key"):
        env = dict(__import__("os").environ, MASK_KEY=key)
        return subprocess.run([sys.executable, str(ROOT / "tools/anonymize_logs.py"), str(self.SAMPLE), "-o", str(d / "m.csv"), *extra],
                              capture_output=True, text=True, env=env)

    def test_csv_masked_consistently_and_structure_kept(self):
        import csv as _csv
        import re as _re
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            r = self.anonymize(d)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            row = next(_csv.DictReader((d / "m.csv").open(encoding="utf-8", newline="")))
            raw = row["_raw"]
            self.assertEqual(row["_time"], "2026-10-08T11:59:16.339+03:00")
            body = json.loads(raw.split("::", 2)[2])
            lr = body["data"]["laborerRequest"]
            self.assertTrue(lr["name"]["firstName"].startswith("masked_"))
            self.assertTrue(lr["name"]["nameEnglish"].startswith("masked_"))
            self.assertTrue(lr["establishmentNameArb"].startswith("masked_"))
            self.assertNotRegex(raw, r"[\u0600-\u06FF]")
            for original in ("1555555555", "777777777", "1222222222", "666666666", "SAMI ALI"):
                self.assertNotIn(original, raw)
            eng = body["data"]["engagementId"]                                   # string form
            self.assertEqual(str(body["data"]["contributions"][0]["engagementId"]), eng)   # number form, same mask
            self.assertTrue(body["resourceUrl"].endswith("/engagement/" + eng))           # inside the URL, same mask
            self.assertEqual(body["data"]["nin"], lr["identity"][0]["newNin"])
            self.assertNotEqual(lr["birthDate"]["gregorian"][:10], "1995-03-15")
            self.assertNotEqual(lr["identity"][0]["oldNinDateOfIssue"]["gregorian"][:10], "2020-01-01")
            self.assertEqual(body["uuid"], "00000000-1111-4222-8333-444444444444")
            self.assertIn("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", raw)                  # ecid kept
            self.assertIn("99999999-8888-4777-8666-555555555555", raw)                  # TraceID kept
            self.assertEqual(body["name"], "update-approved")
            self.assertEqual(lr["wage"], 5000)
            rep = json.loads((d / "m.csv.report.json").read_text())
            self.assertEqual(rep["residue_check"]["findings"], 0)
            self.assertTrue(rep["key_inventory"]["firstName"]["masked"])
            self.assertFalse(rep["key_inventory"]["wage"]["masked"])
            self.assertNotIn("SAMI", (d / "m.csv.report.json").read_text())   # the report holds no values

    def test_same_key_same_result_other_key_differs(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            self.anonymize(d); a = (d / "m.csv").read_text()
            self.anonymize(d); b = (d / "m.csv").read_text()
            self.anonymize(d, key="other"); c = (d / "m.csv").read_text()
            self.assertEqual(a, b)
            self.assertNotEqual(a, c)

    def test_refuses_without_key(self):
        with tempfile.TemporaryDirectory() as d:
            env = {k: v for k, v in __import__("os").environ.items() if k != "MASK_KEY"}
            r = subprocess.run([sys.executable, str(ROOT / "tools/anonymize_logs.py"), str(self.SAMPLE), "-o", str(Path(d) / "m.csv")],
                               capture_output=True, text=True, env=env)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("MASK_KEY", r.stderr)

    def test_extra_key_is_masked_and_reported(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            self.anonymize(d, "--mask-json-key", "workType")
            raw = (d / "m.csv").read_text(encoding="utf-8")
            self.assertNotIn("FullTime", raw)
            self.assertTrue(json.loads((d / "m.csv.report.json").read_text())["key_inventory"]["workType"]["masked"])


class ExampleSignatureTests(unittest.TestCase):
    def test_masked_numbers_never_get_a_leading_zero(self):
        m = trmod.Masker(trmod.DEFAULT_MASKS, trmod.DEFAULT_JSON_KEYS, key=b"k")
        for n in range(1000000000, 1000000400):
            out = m(f'{{"nin":{n}}}')
            json.loads(out)                                   # must stay valid JSON
            self.assertNotEqual(json.loads(out)["nin"], n)

    def test_log_only_chain_anonymise_signature_traces_fixtures(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            env = dict(__import__("os").environ, MASK_KEY="k")
            subprocess.run([sys.executable, str(ROOT / "tools/anonymize_logs.py"), str(SAMPLES / "splunk-export-synthetic.csv"),
                            "-o", str(d / "e.masked.csv")], check=True, capture_output=True, env=env)
            out = run(ROOT / "tools/signature_from_example.py", d / "e.masked.csv", "-o", d / "sig.json")
            info = json.loads(out.stdout)
            self.assertEqual(info["matches_in_file"], "1/1")
            self.assertEqual(info["signature"], "sample-change-prj/sample-adjustment#example-request")
            self.assertIn("hdr_resource", info["groups"])
            run(ROOT / "tools/osb_log_traces.py", d / "sig.json", d / "e.masked.csv", "-o", d / "t", "--already-masked")
            tr = [json.loads(l) for l in (d / "t/traces.jsonl").read_text().splitlines()]
            self.assertEqual(len(tr), 1)
            self.assertTrue(tr[0]["has_payload"])
            self.assertEqual(tr[0]["branch"], {"hdr_resource": "Contributory Wage"})
            json.loads(tr[0]["events"][0]["fields"]["body"])        # payload still valid JSON after masking


class ScenarioDimsTests(unittest.TestCase):
    def test_body_path_dimension(self):
        f = {"hdr_resource": "R", "body": '{"data":{"businessTransaction":"MANAGE_WAGE","list":[1]}}'}
        self.assertEqual(trmod.dim_value(f, "hdr_resource"), "R")
        self.assertEqual(trmod.dim_value(f, "body:data.businessTransaction"), "MANAGE_WAGE")
        self.assertEqual(trmod.dim_value(f, "body:data.missing"), "?")
        self.assertEqual(trmod.dim_value(f, "body:data.list"), "?")          # containers never split scenarios
        self.assertEqual(trmod.dim_value({"body": "<xml/>"}, "body:a"), "?")  # non-JSON payload
