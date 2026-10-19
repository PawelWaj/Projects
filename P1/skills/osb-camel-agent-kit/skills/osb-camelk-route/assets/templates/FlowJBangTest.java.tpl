///usr/bin/env jbang "$0" "$@" ; exit $?
//JAVA 21+
//DEPS org.apache.camel:camel-bom:@@CAMEL@@@pom
//DEPS org.apache.camel:camel-core-engine
//DEPS org.apache.camel:camel-main
//DEPS org.apache.camel:camel-yaml-dsl
//DEPS org.apache.camel:camel-direct
//DEPS org.apache.camel:camel-mock
//DEPS org.apache.camel:camel-bean
//DEPS org.apache.camel:camel-log
//DEPS org.apache.camel:camel-jackson
//DEPS net.sf.saxon:Saxon-HE:12.9
//DEPS org.junit.platform:junit-platform-console-standalone:1.12.2
//DEPS org.slf4j:slf4j-simple:2.0.17
//SOURCES ../../Common-setup/OsbNxsd.java
//SOURCES ../../Common-setup/OsbXQuery.java

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.apache.camel.CamelContext;
import org.apache.camel.Exchange;
import org.apache.camel.ExchangePattern;
import org.apache.camel.ProducerTemplate;
import org.apache.camel.component.mock.MockEndpoint;
import org.apache.camel.impl.DefaultCamelContext;
import org.apache.camel.support.PluginHelper;
import org.apache.camel.support.ResourceHelper;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestFactory;
import org.junit.jupiter.api.TestInstance;
import org.w3c.dom.Document;

import javax.xml.parsers.DocumentBuilderFactory;
import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.UUID;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Tests of flow @@PROXY@@, no pom and no broker: `jbang test/@@CLASS@@.java` in the project folder.
 * The route file is loaded unchanged; every endpoint property is replaced by direct:/mock:, so the kamelets (and their
 * broker connection) are never created. Cases: test/resources/@@PROXY@@/parity/** (masked log messages, synthetic
 * cases where the logs had none). Expected queue per case = the frozen scenario table (flow-test.json).
 * Body checks: error queue = the original message unchanged; other queues = well-formed XML when the OSB pipeline
 * sends XML (docs/@@PROXY@@/BODY_CHAIN.md), and equal to expected-output.xml where one exists (OSB's real output).
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
public class @@CLASS@@ {
    static final String PROXY = "@@PROXY@@";
    static final Path RES = Path.of("test/resources", PROXY);
    static final List<String> ERROR_HEADERS = List.of(@@ERROR_HEADERS@@);
    static final ObjectMapper JSON = new ObjectMapper();
    static final String[] PROPS = {@@PROPS@@
    };

    CamelContext camel;
    ProducerTemplate producer;
    JsonNode cfg;

    /** `jbang test/@@CLASS@@.java`: runs this class with the JUnit platform, one line per test, exit 1 on a failure. */
    public static void main(String... args) {
        var request = org.junit.platform.launcher.core.LauncherDiscoveryRequestBuilder.request()
            .selectors(org.junit.platform.engine.discovery.DiscoverySelectors.selectClass(@@CLASS@@.class)).build();
        var summary = new org.junit.platform.launcher.listeners.SummaryGeneratingListener();
        var lines = new org.junit.platform.launcher.TestExecutionListener() {
            @Override
            public void executionFinished(org.junit.platform.launcher.TestIdentifier id, org.junit.platform.engine.TestExecutionResult r) {
                if (id.isTest()) {
                    System.out.println((r.getStatus() == org.junit.platform.engine.TestExecutionResult.Status.SUCCESSFUL ? "PASS " : "FAIL ")
                        + id.getDisplayName() + r.getThrowable().map(t -> "  -> " + t.getMessage()).orElse(""));
                }
            }
        };
        org.junit.platform.launcher.core.LauncherFactory.create().execute(request, summary, lines);
        var s = summary.getSummary();
        System.out.printf("%d tests, %d failed%n", s.getTestsFoundCount(), s.getTotalFailureCount());
        System.exit(s.getTotalFailureCount() == 0 && s.getTestsFoundCount() > 0 ? 0 : 1);
    }

    @BeforeAll
    void start() throws Exception {
        cfg = JSON.readTree(RES.resolve("flow-test.json").toFile());
        camel = new DefaultCamelContext();
        Properties p = new Properties();
        for (String kv : PROPS) {
            int i = kv.indexOf('=');
            p.setProperty(kv.substring(0, i), kv.substring(i + 1));
        }
        camel.getPropertiesComponent().setOverrideProperties(p);
        PluginHelper.getRoutesLoader(camel).loadRoutes(ResourceHelper.resolveResource(camel, "file:@@ROUTE@@"));
        camel.start();
        producer = camel.createProducerTemplate();
    }

    @AfterAll
    void stop() {
        camel.stop();
    }

    String mockOf(String output) {
        return "mock:" + PROXY + "-" + output;
    }

    List<String> outputs() {
        List<String> l = new ArrayList<>();
        cfg.path("outputs").fieldNames().forEachRemaining(o -> { if (!"reply".equals(o)) l.add(o); });
        return l;
    }

    /** Sends one message; every output in targets must receive exactly one message, every other none. */
    Map<String, Exchange> send(String body, Map<String, Object> headers, List<String> targets) throws Exception {
        MockEndpoint.resetMocks(camel);
        for (String o : outputs()) {
            MockEndpoint m = camel.getEndpoint(mockOf(o), MockEndpoint.class);
            m.expectedMessageCount(targets.contains(o) ? 1 : 0);
            m.setResultWaitTime(2000);
        }
        producer.send("direct:in-" + PROXY, ExchangePattern.InOnly, e -> {
            e.getMessage().setBody(body);
            e.getMessage().setHeaders(new HashMap<>(headers));
        });
        Map<String, Exchange> got = new HashMap<>();
        for (String o : outputs()) {
            MockEndpoint m = camel.getEndpoint(mockOf(o), MockEndpoint.class);
            m.assertIsSatisfied();
            if (!m.getExchanges().isEmpty()) {
                got.put(o, m.getExchanges().get(0));
            }
        }
        return got;
    }

    static boolean matches(String key, Map<String, String> values) {
        if (key.isBlank()) {
            return false;
        }
        for (String part : key.split("\\|")) {
            int ne = part.indexOf("!=");
            int eq = part.indexOf('=');
            if (ne > 0 && part.substring(ne + 2).equals(values.get(part.substring(0, ne)))) {
                return false;
            }
            if (ne < 0 && eq > 0 && !part.substring(eq + 1).equals(values.get(part.substring(0, eq)))) {
                return false;
            }
        }
        return true;
    }

    List<String> expectedOutputs(Path c) throws Exception {
        JsonNode exp = Files.exists(c.resolve("expected.json")) ? JSON.readTree(c.resolve("expected.json").toFile()) : JSON.createObjectNode();
        if (!"success".equals(exp.path("outcome").asText("success"))) {
            return List.of(cfg.path("error_output").asText());
        }
        Path sc = c.getParent().resolve("SCENARIO.txt");
        Map<String, String> values = new HashMap<>();
        for (String part : (Files.exists(sc) ? Files.readString(sc).strip() : "").split("\\|")) {
            int i = part.indexOf('=');
            if (i > 0) {
                values.put(part.substring(0, i), part.substring(i + 1));
            }
        }
        for (JsonNode m : cfg.path("scenario_mapping")) {
            if (matches(m.path("scenario").asText(), values)) {
                List<String> outs = new ArrayList<>();
                m.path("outputs").forEach(o -> outs.add(o.asText()));
                return outs;
            }
        }
        throw new AssertionError("scenario not mapped in flow-test.json: " + values);
    }

    @SuppressWarnings("unchecked")
    Map<String, Object> headersOf(Path c) throws Exception {
        Path h = c.resolve("headers.json");
        return Files.exists(h) ? JSON.readValue(h.toFile(), Map.class) : new HashMap<>();
    }

    static Document xml(String s) throws Exception {
        DocumentBuilderFactory f = DocumentBuilderFactory.newInstance();
        f.setNamespaceAware(true);
        f.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
        return f.newDocumentBuilder().parse(new ByteArrayInputStream(s.getBytes(StandardCharsets.UTF_8)));
    }

    /** Values OSB generates per call (fn-bea:uuid, current time) are compared by presence only. */
    static String canonical(String s) throws Exception {
        Document d = xml(s);
        d.normalizeDocument();
        var t = javax.xml.transform.TransformerFactory.newInstance().newTransformer();
        t.setOutputProperty(javax.xml.transform.OutputKeys.OMIT_XML_DECLARATION, "yes");
        var w = new java.io.StringWriter();
        t.transform(new javax.xml.transform.dom.DOMSource(d), new javax.xml.transform.stream.StreamResult(w));
        return w.toString().replaceAll(">\\s+<", "><")
            .replaceAll(">[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}<", ">GENERATED<")
            .replaceAll(">\\d{4}-\\d{2}-\\d{2}T[0-9:.]+(Z|[+-]\\d{2}:\\d{2})?<", ">GENERATED<");
    }

    Stream<Path> cases() throws Exception {
        Path parity = RES.resolve("parity");
        if (!Files.isDirectory(parity)) {
            return Stream.empty();
        }
        try (Stream<Path> s = Files.walk(parity)) {
            return s.filter(p -> p.getFileName().toString().equals("input.payload")).map(Path::getParent).sorted().toList().stream();
        }
    }

    @Test
    void casesArePresent() throws Exception {
        assertFalse(cases().toList().isEmpty(), "no test cases under " + RES.resolve("parity"));
    }

    @TestFactory
    Stream<DynamicTest> eachCaseReachesTheQueueOsbUsed() throws Exception {
        return cases().map(c -> DynamicTest.dynamicTest(RES.relativize(c).toString(), () -> {
            String in = Files.readString(c.resolve("input.payload"));
            List<String> targets = expectedOutputs(c);
            Map<String, Exchange> got = send(in, headersOf(c), targets);
            String err = cfg.path("error_output").asText();
            for (var e : got.entrySet()) {
                String body = e.getValue().getMessage().getBody(String.class);
                if (e.getKey().equals(err)) {
                    assertEquals(in, body, "error queue gets the original message (OSB: replace $body with $request)");
                    continue;
                }
                assertNull(e.getValue().getMessage().getHeader("resource"), "OSB sends no transport headers on " + e.getKey());
                if (body != null && body.stripLeading().startsWith("<")) {
                    assertNotNull(xml(body), "well-formed XML on " + e.getKey());
                }
                Path golden = c.resolve("expected-output.xml");
                if (Files.exists(golden)) {
                    assertEquals(canonical(Files.readString(golden)), canonical(body), "body differs from OSB's real output");
                }
            }
        }));
    }

    @Test
    void unreadableMessageGoesToTheErrorQueueUnchanged() throws Exception {
        Path first = cases().findFirst().orElseThrow();
        Map<String, Object> h = headersOf(first);
        String err = cfg.path("error_output").asText();
        Exchange e = send("{[[ not a message", h, List.of(err)).get(err);
        assertEquals("{[[ not a message", e.getMessage().getBody(String.class));
        for (String name : ERROR_HEADERS) {
            if (List.of("errorCode", "errorMessage", "debugInfo").contains(name) || h.containsKey(name)) {
                assertNotNull(e.getMessage().getHeader(name), name + " must be set on the error queue (OSB transport-headers)");
            }
        }
    }

    @Test
    void traceIdIsGeneratedWhenMissing() throws Exception {
        if (!cfg.path("correlation_generated").asBoolean(false)) {
            return;
        }
        String corr = cfg.path("correlation_header").asText("traceId");
        String err = cfg.path("error_output").asText();
        Exchange e = send("{[[ not a message", new HashMap<>(), List.of(err)).get(err);
        assertNotNull(UUID.fromString(e.getMessage().getHeader(corr, String.class)), corr + " generated (OSB fn-bea:uuid)");
    }
}
