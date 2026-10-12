"""Writes docs/osb_log_replay.drawio (page 1: from OSB source and logs to tests; page 2: mock architecture).
Export PNGs with the draw.io desktop CLI: draw.io -x -f png -s 2 -p <page> -o <file>.png osb_log_replay.drawio"""
from html import escape
from pathlib import Path

INK, MINT, GREY = "#06041F", "#47D7AC", "#8893A5"
T_MINT, T_GREY, AMBER, AMBER_LN, RED, RED_LN, WHITE = "#EAF9F4", "#EEF1F4", "#FEF3D0", "#9A6B0F", "#FBEAEA", "#B02A2A", "#FFFFFF"


class Page:
    def __init__(self, pid, name, w, h):
        self.pid, self.name, self.w, self.h, self.cells, self.n = pid, name, w, h, [], 0

    def _id(self):
        self.n += 1
        return f"{self.pid}-{self.n}"

    def box(self, x, y, w, h, html, fill=T_GREY, stroke=GREY, font=12, sw=1, dashed=False, align="center"):
        i = self._id()
        st = (f"rounded=1;whiteSpace=wrap;html=1;fillColor={fill};strokeColor={stroke};fontColor={INK};fontSize={font};arcSize=8;"
              f"strokeWidth={sw};align={align};verticalAlign=middle;spacing=6;{'dashed=1;' if dashed else ''}")
        self.cells.append(f'<mxCell id="{i}" value="{escape(html)}" style="{st}" vertex="1" parent="1"><mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/></mxCell>')
        return i

    def text(self, x, y, w, h, html, font=12, color=INK):
        i = self._id()
        st = f"text;html=1;whiteSpace=wrap;fontSize={font};fontColor={color};align=left;verticalAlign=middle;"
        self.cells.append(f'<mxCell id="{i}" value="{escape(html)}" style="{st}" vertex="1" parent="1"><mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/></mxCell>')

    def edge(self, a, b, label="", color=INK, dashed=False, ex=None, en=None, pts=None, width=1.5):
        i = self._id()
        st = (f"edgeStyle=orthogonalEdgeStyle;rounded=1;html=1;strokeColor={color};strokeWidth={width};endArrow=block;endFill=1;"
              f"fontSize=10;labelBackgroundColor={WHITE};{'dashed=1;' if dashed else ''}")
        if ex:
            st += f"exitX={ex[0]};exitY={ex[1]};exitDx=0;exitDy=0;"
        if en:
            st += f"entryX={en[0]};entryY={en[1]};entryDx=0;entryDy=0;"
        geo = '<mxGeometry relative="1" as="geometry">' + (
            "<Array as=\"points\">" + "".join(f'<mxPoint x="{px}" y="{py}"/>' for px, py in pts) + "</Array>" if pts else "") + "</mxGeometry>"
        self.cells.append(f'<mxCell id="{i}" value="{escape(label)}" style="{st}" edge="1" parent="1" source="{a}" target="{b}">{geo}</mxCell>')

    def xml(self):
        return (f'<diagram id="{self.pid}" name="{escape(self.name)}"><mxGraphModel grid="0" page="1" pageWidth="{self.w}" pageHeight="{self.h}" '
                f'background="#FFFFFF"><root><mxCell id="0"/><mxCell id="1" parent="0"/>{"".join(self.cells)}</root></mxGraphModel></diagram>')


def page1():
    p = Page("flow", "1 From OSB logs to tests", 1700, 980)
    p.text(30, 15, 1500, 34, "<b>From OSB source and Splunk logs to tests</b>: understand the logging first, then search, then test", 21)
    lanes = [("OSB SOURCE", 70), ("SPLUNK", 260), ("ANALYSIS (stdlib tools)", 450), ("TEST ASSETS", 640), ("TEST LAYERS", 790)]
    for name, y in lanes:
        p.box(20, y, 1660, 170 if name != "TEST LAYERS" else 165, "", fill="#FAFBFC", stroke="#DDE2E8")
        p.text(30, y + 4, 300, 20, f"<b>{name}</b>", 11, GREY)
    src = p.box(60, 105, 270, 110, "<b>OSB export</b><br>.pipeline / .proxy<br>Log actions = XQuery fn:concat<br>of fixed text + $uuId, headers, $body, $fault", WHITE, INK)
    s1 = p.box(400, 105, 300, 110, "<b>1 Log signatures</b><br><code>osb_log_signatures.py</code><br>regex per Log action, anchor,<br>roles: correlation · payload · fault · headers", T_MINT, MINT, sw=2)
    warn = p.box(770, 105, 330, 110, "<b>What the source already tells you</b><br>debug lines usually OFF in PROD (payload!)<br>outputs to queues are not logged<br>selector-rejected messages never logged", AMBER, AMBER_LN)
    s2 = p.box(400, 295, 300, 110, "<b>2 Splunk searches</b><br><code>spl_from_signatures.py</code><br>anchor + rex per signature;<br>trace search grouped by correlation id", T_MINT, MINT, sw=2)
    spl = p.box(770, 295, 330, 110, "<b>Check before exporting</b><br>index + sourcetype from the owner<br>multi-line events not split (####&lt; breaker)<br>no truncation · full business cycle", AMBER, AMBER_LN)
    exp = p.box(1170, 295, 300, 110, "<b>Export _raw + _time</b><br><code>splunk_export.py</code> (REST, token from env)<br>or CSV from the UI", WHITE, INK)
    s3 = p.box(1170, 485, 300, 110, "<b>3 Traces + scenarios</b><br><code>osb_log_traces.py</code><br>WebLogic envelope off · match · MASK<br>group by correlation · outcome · branch", T_MINT, MINT, sw=2)
    cov = p.box(770, 485, 330, 110, "<b>coverage.json · scenarios.json</b><br>signatures never seen · traces without payload<br>scenarios by frequency (top = traffic,<br>rare = where migrations break)", WHITE, INK)
    s4 = p.box(400, 485, 300, 110, "<b>4 Fixtures</b><br><code>fixtures_from_traces.py</code><br>N traces per scenario with a payload", T_MINT, MINT, sw=2)
    fx = p.box(60, 675, 420, 100, "<b>parity/&lt;flow&gt;/&lt;scenario&gt;/&lt;trace&gt;/</b><br>input.payload · headers.json · expected.json<br>golden/MANIFEST.csv: source = osb-recording (gate G7)", WHITE, INK)
    gold = p.box(560, 675, 420, 100, "<b>expected-output.xml</b><br>ORIGINAL XQuery/XSLT run on input.payload<br>(logs do not hold the output) · source = original-transform", WHITE, INK)
    neg = p.box(1060, 675, 410, 100, "<b>negative_cases</b> in replay-config.json<br>from the proxy JMS selector, not from logs", WHITE, INK)
    u = p.box(60, 825, 420, 110, "<b>Unit tests: the base</b><br>agent tester role writes route tests from the flow card,<br>fixture inputs, backends mocked · every build", T_MINT, MINT, sw=2)
    g = p.box(560, 825, 420, 110, "<b>Golden tests</b><br>migrated transform == original transform<br>on recorded inputs, quirks included · every build", T_MINT, MINT, sw=2)
    e = p.box(1060, 825, 410, 110, "<b>5 E2E replay on the mock architecture</b><br><code>replay_runner.py</code>: broker filter, routing,<br>error-queue headers, golden body · junit.xml", T_MINT, MINT, sw=2)
    p.edge(src, s1, "parse")
    p.edge(s1, warn, "", GREY, True)
    p.edge(s1, s2, "", ex=(0.5, 1), en=(0.5, 0))
    p.edge(s2, spl, "", GREY, True)
    p.edge(spl, exp, "")
    p.edge(exp, s3, "", ex=(0.5, 1), en=(0.5, 0))
    p.edge(s3, cov, "")
    p.edge(cov, s4, "")
    p.edge(s4, fx, "", ex=(0.3, 1), en=(0.6, 0), pts=[(490, 640), (312, 640)])
    p.edge(s4, gold, "", ex=(0.7, 1), en=(0.4, 0), pts=[(610, 640), (728, 640)])
    p.edge(fx, u, "", ex=(0.5, 1), en=(0.5, 0))
    p.edge(gold, g, "", ex=(0.5, 1), en=(0.5, 0))
    p.edge(neg, e, "", ex=(0.5, 1), en=(0.5, 0))
    p.edge(u, g, "then")
    p.edge(g, e, "then")
    return p


def page2():
    p = Page("mock", "2 Mock architecture", 1600, 760)
    p.text(30, 15, 1500, 34, "<b>Mock architecture</b> (mock/docker-compose.yml): the Camel flow under test is a black box between broker and backends", 20)
    run = p.box(60, 200, 250, 120, "<b>replay_runner.py</b><br>publishes input.payload<br>+ headers.json per fixture", WHITE, INK, sw=1.5)
    p.box(380, 80, 760, 420, "", fill="#FAFBFC", stroke="#DDE2E8")
    p.text(395, 86, 400, 22, "<b>ARTEMIS (mock broker)</b>   setup_broker.sh creates these from replay-config.json", 11, GREY)
    topic = p.box(410, 200, 230, 120, "<b>orderEventsTopic</b><br>multicast address<br>(the OSB proxy's topic)", T_GREY)
    sub = p.box(700, 200, 260, 120, "<b>order-event-sub</b><br>durable subscription queue<br>filter = the proxy's JMS selector", T_MINT, MINT, sw=2)
    okq = p.box(700, 360, 200, 60, "<b>InboundOrderEventQueue</b>", T_GREY)
    errq = p.box(920, 360, 200, 60, "<b>orderEventErrorQueue</b>", RED, RED_LN)
    sut = p.box(1210, 200, 330, 120, "<b>Flow under test</b> (profile sut)<br>Camel K integration or Camel on Spring Boot<br>consumes order-event-sub (FQQN)", T_MINT, MINT, sw=2)
    stub = p.box(1210, 90, 330, 70, "<b>sut-stub</b> (profile selftest): proves the harness<br>before the real flow exists", WHITE, GREY, dashed=True)
    wm = p.box(1210, 540, 330, 90, "<b>WireMock</b><br>HTTP / SOAP backends (business services)<br>stubs in mock/wiremock/mappings", T_GREY)
    rep = p.box(60, 560, 480, 110, "<b>report.json · junit.xml</b><br>per fixture: outcome == expected destination,<br>required headers present, body == expected-output.xml", WHITE, INK)
    neg = p.box(620, 560, 480, 110, "<b>Negative cases</b><br>headers the selector must reject (from replay-config.json)<br>pass = nothing arrives on any output queue", AMBER, AMBER_LN)
    p.edge(run, topic, "publish")
    p.edge(topic, sub, "filter")
    p.edge(sub, sut, "consume")
    p.edge(sut, okq, "success", ex=(0.15, 1), en=(0.5, 0), pts=[(1259, 340), (800, 340)])
    p.edge(sut, errq, "error + headers", RED_LN, ex=(0.85, 1), en=(1, 0.5), pts=[(1490, 390)])
    p.edge(sut, wm, "calls", GREY, True, ex=(0.5, 1), en=(0.5, 0))
    p.edge(okq, run, "wait for same correlation id", GREY, True, ex=(0, 0.5), en=(0.5, 1), pts=[(185, 390)])
    p.edge(run, rep, "report", ex=(0.2, 1), en=(0.1, 0))
    return p


def page3():
    p = Page("once", "3 One-time flow (pilot)", 1900, 900)
    p.text(30, 12, 1840, 34, "<b>One-time flow for the pilot flow</b>: from Splunk logs to test cases, run once by one engineer, no CI needed", 21)
    lanes = [("YOU (engineer)", 70, 170), ("SPLUNK UI", 255, 150), ("SCRIPTS (python)", 420, 170), ("WHAT YOU GET", 605, 150)]
    for name, y, h in lanes:
        p.box(20, y, 1860, h, "", fill="#FAFBFC", stroke="#DDE2E8")
        p.text(30, y + 6, 400, 20, f"<b>{name}</b>", 11, GREY)
    W, H = 270, 120
    xs = [60, 360, 660, 960, 1260, 1560]
    s1 = p.box(xs[0], 445, W, H, "<b>1 Read the logging</b><br><code>osb_log_signatures.py</code><br>on the OSB project: which lines,<br>which one has the payload,<br>log level, correlation id", T_MINT, MINT, sw=2)
    s2 = p.box(xs[1], 445, W, H, "<b>2 Make the searches</b><br><code>spl_from_signatures.py</code><br>→ queries.spl:<br>EXPORT search per flow", T_MINT, MINT, sw=2)
    u3 = p.box(xs[2], 275, W, H, "<b>3 Run the EXPORT search</b><br>time range 7-30 days<br>check: lines found? payload line there?<br>one event per log line?<br>→ <b>Export → CSV</b> (_time, _raw)", AMBER, AMBER_LN, sw=1.5)
    s4 = p.box(xs[3], 445, W, H, "<b>4 Analyse</b><br><code>osb_log_traces.py</code> on the CSV<br>mask · group by correlation id<br>→ scenarios + coverage", T_MINT, MINT, sw=2)
    y5 = p.box(xs[4], 95, W, H, "<b>5 Decide</b><br>scenarios vs the flow card<br>gaps: no payload, never-seen lines<br>pick the scenarios to test", AMBER, AMBER_LN, sw=1.5)
    s6 = p.box(xs[5], 445, W, H, "<b>6 Test cases</b><br><code>fixtures_from_traces.py</code><br>+ golden output from the<br>ORIGINAL XQuery (skill /osb-test)", T_MINT, MINT, sw=2)
    y1 = p.box(xs[0], 95, W, H, "<b>Start</b><br>copy the OSB project to osb-src/<br>(the same files the estimate used)", WHITE, INK)
    gap = p.box(xs[2], 95, W, H, "<b>No payload lines?</b><br>debug logging is off: enable debug<br>for this proxy in a test environment,<br>or use Report action / tracing", RED, RED_LN)
    o1 = p.box(xs[0], 630, W, 105, "signatures.json<br>(what OSB writes, per Log action)", WHITE, INK)
    o2 = p.box(xs[1], 630, W, 105, "queries.spl<br>(copy-paste into Splunk)", WHITE, INK)
    o3 = p.box(xs[2], 630, W, 105, "events.csv<br>(raw OSB log lines)", WHITE, INK)
    o4 = p.box(xs[3], 630, W, 105, "scenarios.json (by frequency)<br>coverage.json (what is missing)", WHITE, INK)
    o5 = p.box(xs[4], 630, W, 105, "list of scenarios to test<br>+ recorded gaps", WHITE, INK)
    o6 = p.box(xs[5], 630, W, 105, "<b>one folder per scenario</b><br>input + headers + expected<br>+ expected output (golden)", T_MINT, MINT, sw=2)
    p.edge(y1, s1, "", ex=(0.5, 1), en=(0.5, 0))
    p.edge(s1, s2, "")
    p.edge(s2, u3, "", ex=(1, 0.3), en=(0, 0.5), pts=[(645, 481), (645, 335)])
    p.edge(u3, s4, "CSV", ex=(1, 0.5), en=(0.5, 0), pts=[(1095, 335)])
    p.edge(u3, gap, "no", RED_LN, True, ex=(0.5, 0), en=(0.5, 1))
    p.edge(gap, u3, "", RED_LN, True, ex=(0.9, 1), en=(0.9, 0))
    p.edge(s4, y5, "", ex=(1, 0.3), en=(0.5, 1), pts=[(1395, 481)])
    p.edge(y5, s6, "", ex=(1, 0.5), en=(0.5, 0), pts=[(1695, 155)])
    for s, o in ((s1, o1), (s2, o2), (s4, o4), (s6, o6)):
        p.edge(s, o, "", GREY, ex=(0.5, 1), en=(0.5, 0))
    p.edge(u3, o3, "", GREY, ex=(0.3, 1), en=(0.5, 0), pts=[(741, 600), (795, 600)])
    p.edge(y5, o5, "", GREY, ex=(0.3, 1), en=(0.5, 0), pts=[(1341, 600), (1395, 600)])
    p.box(60, 790, 1770, 80, "<b>Then use the test cases</b>: the tester role of the agent kit writes unit tests with these inputs (the base); golden tests compare the migrated transform with the original; "
          "if Docker is available, replay them end to end on the mock architecture (page 2). Every test value comes from OSB evidence, never from the new code.", T_GREY, GREY)
    return p


def page4():
    p = Page("auto", "4 Later: automate (optional)", 1900, 1060)
    p.text(30, 12, 1800, 34, "<b>Later, optional: automating it</b> once the one-time flow has proven the method. Scripts do the work, the AI agent writes and fixes tests, humans set up once and decide at three points", 21)
    cols = [("P0  ONCE PER OSB EXPORT", 250), ("P1  SCHEDULED LOG HARVEST", 640), ("P2  PER FLOW: BUILD TESTS", 1030), ("P3  PER FLOW: VERIFY", 1420)]
    for name, x in cols:
        p.text(x, 50, 360, 22, f"<b>{name}</b>", 12, GREY)
    lanes = [("TRIGGER", 80, 120), ("SCRIPTS (no AI)", 215, 190), ("AI AGENT (pi roles)", 420, 150), ("HUMANS", 585, 135), ("RESULT", 735, 150)]
    for name, y, h in lanes:
        p.box(20, y, 1860, h, "", fill="#FAFBFC", stroke="#DDE2E8")
        p.text(30, y + 6, 200, 20, f"<b>{name}</b>", 11, GREY)
    W = 350
    t0 = p.box(250, 105, W, 75, "<b>New OSB export pushed to Git</b><br>(osb-src/)", WHITE, INK)
    t1 = p.box(640, 105, W, 75, "<b>Jenkins cron, weekly</b><br>+ on demand per flow", WHITE, INK)
    t2 = p.box(1030, 105, W, 75, "<b>Flow card approved</b><br>(gate A of the agent kit)", WHITE, INK)
    t3 = p.box(1420, 105, W, 75, "<b>Camel flow image built</b><br>(every change of the flow)", WHITE, INK)
    s0 = p.box(250, 245, W, 135, "<b>Catalogue</b><br><code>osb_inventory.py</code> + <code>osb_log_signatures.py</code><br>all flows: signatures, warnings,<br><b>replay-config generated</b> from proxy/bix<br>(selector, topic, queues) + name map", T_MINT, MINT, sw=2)
    s1 = p.box(640, 245, W, 135, "<b>Harvest</b><br><code>spl_from_signatures</code> → <code>splunk_export</code><br>(service token from Jenkins credentials)<br>→ <code>osb_log_traces</code>: traces, scenarios,<br>coverage, masking, per flow", T_MINT, MINT, sw=2)
    s2 = p.box(1030, 245, W, 135, "<b>Fixtures + golden</b><br><code>fixtures_from_traces</code> (top + rare scenarios)<br><b>golden outputs</b>: ORIGINAL XQuery on<br>each input (Saxon + fn-bea shim)<br>→ src/test/resources of the module", T_MINT, MINT, sw=2)
    s3 = p.box(1420, 245, W, 135, "<b>Replay in CI</b><br>docker compose: Artemis + WireMock + flow<br><code>setup_broker.sh</code> → <code>replay_runner.py</code><br>→ junit.xml = <b>gate G9</b><br>(after gates G1-G8)", T_MINT, MINT, sw=2)
    a0 = p.box(250, 450, W, 100, "<b>Explain weak signatures</b><br>no correlation field, ambiguous split,<br>debug-only payload: propose a fix", WHITE, GREY)
    a1 = p.box(640, 450, W, 100, "<b>Explain coverage gaps</b><br>signatures never seen, traces without<br>payload: propose the cheapest option", WHITE, GREY)
    a2 = p.box(1030, 450, W, 100, "<b>Tester role writes unit tests</b><br>from the card's test matrix,<br>fixture inputs as test data (the base)", T_MINT, MINT, sw=1.5)
    a3 = p.box(1420, 450, W, 100, "<b>Implementer fixes red</b><br>production code only, max 3 loops;<br>reviewer adds replay evidence to the record", T_MINT, MINT, sw=1.5)
    h0 = p.box(250, 610, W, 95, "<b>Once</b>: Splunk index + sourcetype,<br>event breaking checked, service token,<br>JNDI → target queue name map", AMBER, AMBER_LN)
    h1 = p.box(640, 610, W, 95, "<b>Decide gaps</b>: enable debug for a flow<br>in test, use Report action / tracing,<br>or accept the gap (recorded)", AMBER, AMBER_LN)
    h2 = p.box(1030, 610, W, 95, "<b>Review a masked sample</b><br>before fixtures leave the<br>secure environment", AMBER, AMBER_LN)
    h3 = p.box(1420, 610, W, 95, "<b>Gate B sign-off</b><br>then the shadow run in E2E<br>and cut-over per flow", AMBER, AMBER_LN)
    r0 = p.box(250, 765, W, 95, "signature catalogue + warnings<br>replay-config.json per flow", WHITE, INK)
    r1 = p.box(640, 765, W, 95, "scenarios by frequency per flow<br>coverage.json", WHITE, INK)
    r2 = p.box(1030, 765, W, 95, "fixtures + MANIFEST (osb-recording)<br>expected-output.xml (original-transform)<br>unit tests", WHITE, INK)
    r3 = p.box(1420, 765, W, 95, "junit.xml, report.json<br>migration record with replay evidence", WHITE, INK)
    dash = p.box(250, 925, 1520, 95, "<b>Coverage dashboard</b> (one row per flow, built from the result files): scenarios seen · scenarios with fixtures · unit tests green · "
                 "golden green · replay green · open gaps. It answers 'which flows are ready for the shadow run' for the whole estate.", T_GREY, GREY)
    for t, s in ((t0, s0), (t1, s1), (t2, s2), (t3, s3)):
        p.edge(t, s, "", ex=(0.5, 1), en=(0.5, 0))
    p.edge(s0, s1, "")
    p.edge(s1, s2, "")
    p.edge(s2, s3, "")
    for s, a in ((s0, a0), (s1, a1), (s2, a2), (s3, a3)):
        p.edge(s, a, "", GREY, True, ex=(0.5, 1), en=(0.5, 0))
    for a, h in ((a0, h0), (a1, h1), (a2, h2), (a3, h3)):
        p.edge(a, h, "", GREY, True, ex=(0.5, 1), en=(0.5, 0))
    for h, r in ((h0, r0), (h1, r1), (h2, r2), (h3, r3)):
        p.edge(h, r, "", ex=(0.5, 1), en=(0.5, 0))
    p.edge(a3, s3, "fix → rerun", RED_LN, True, ex=(1, 0.3), en=(1, 0.75), pts=[(1810, 480), (1810, 346)])
    return p


def page5():
    p = Page("mocking", "5 How to mock (three levels)", 1900, 1000)
    p.text(30, 12, 1840, 34, "<b>How to mock</b>: the same recorded cases at three levels; each level replaces less of the outside world", 21)
    rc = p.box(40, 380, 260, 200, "<b>Recorded cases</b><br>(one-time flow)<br><br>input.payload<br>headers.json<br>expected.json<br>expected-output.xml<br>(original XQuery)", T_MINT, MINT, sw=2)
    cols = [
        ("LEVEL 1 · UNIT", "no Docker · every build · gate G4", "<code>RecordedCasesRouteTest</code><br>JUnit + Camel AdviceWith",
         "the route's logic: transforms,<br>branches, error handling", "input → <code>direct:in</code><br>queues → <code>mock:success</code> / <code>mock:error</code><br>backends → <code>mock:backend</code>",
         "outcome per real message,<br>error headers, body == golden", "mvn test -Dtest=RecordedCasesRouteTest"),
        ("LEVEL 2 · COMPONENT", "Docker on the build machine · gate G5", "<code>RecordedCasesBrokerIT</code><br>JUnit + Testcontainers + WireMock",
         "the route + a REAL Artemis broker<br>(subscription filter = old selector)", "backends → WireMock stubs from the .bix<br>(reply, fault, delay > timeout)",
         "selector, transactions, redelivery,<br>headers on the wire, timeouts", "mvn verify -Dit.test=RecordedCasesBrokerIT"),
        ("LEVEL 3 · END TO END", "Docker Compose · per built image · gate G9", "<code>mock/docker-compose.yml</code><br>+ <code>replay_runner.py</code>",
         "the BUILT flow image (Camel K or<br>Spring Boot) + Artemis + WireMock", "nothing inside the flow;<br>only the backends (WireMock)",
         "the deployable artefact behaves<br>like OSB on recorded traffic", "docker compose --profile sut up -d<br>docker compose --profile replay run --rm replay"),
    ]
    xs = [380, 900, 1420]
    heads = []
    for (title, when, tool, real, mocked, proves, cmd), x in zip(cols, xs):
        h = p.box(x, 70, 440, 90, f"<b>{title}</b><br>{when}", INK if False else WHITE, INK, font=13, sw=2)
        heads.append(h)
        p.box(x, 180, 440, 80, tool, T_GREY, GREY)
        p.box(x, 280, 440, 100, f"<b>REAL</b><br>{real}", T_MINT, MINT, sw=1.5)
        p.box(x, 400, 440, 100, f"<b>MOCKED</b><br>{mocked}", T_GREY, GREY, dashed=True)
        p.box(x, 520, 440, 100, f"<b>PROVES</b><br>{proves}", WHITE, INK)
        p.box(x, 640, 440, 90, f"<b>RUN</b><br><code>{cmd}</code>", "#F6F7F9", GREY)
    p.edge(rc, heads[0], "feeds all three levels", GREY, ex=(0.5, 0), en=(0, 0.5), pts=[(170, 115)])
    p.edge(heads[0], heads[1], "then")
    p.edge(heads[1], heads[2], "then")
    p.box(380, 770, 1480, 70, "<b>Not mocked: Splunk.</b> Export once to CSV (one-time flow) and work offline; samples/ for development. "
          "<b>Generated ids and time:</b> correlation id from headers.json; time fields ignored in comparisons.", AMBER, AMBER_LN)
    done = p.box(380, 870, 1000, 90, "<b>Done when</b> level 1 is green for every recorded case, level 2 where the flow has a selector, transactions or backends, "
                 "and level 3 on the built image", T_MINT, MINT, sw=2)
    nxt = p.box(1460, 870, 400, 90, "<b>Then</b>: shadow run in a real environment<br>and sign-off (agent kit)", WHITE, INK)
    p.edge(done, nxt, "")
    return p


out = Path(__file__).with_name("osb_log_replay.drawio")
out.write_text('<mxfile host="build_diagram.py">' + page1().xml() + page2().xml() + page3().xml() + page4().xml() + page5().xml() + "</mxfile>", encoding="utf-8")
print("wrote", out)
