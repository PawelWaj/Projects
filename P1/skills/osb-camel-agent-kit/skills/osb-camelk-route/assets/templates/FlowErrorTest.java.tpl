package @@PACKAGE@@;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.apache.camel.CamelContext;
import org.apache.camel.Exchange;
import org.apache.camel.ExchangePattern;
import org.apache.camel.Produce;
import org.apache.camel.ProducerTemplate;
import org.apache.camel.component.mock.MockEndpoint;
import org.apache.camel.test.main.junit5.CamelMainTest;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;

/**
 * Error tests for OSB project @@PROJECT@@, proxy @@PROXY@@: one test per error scope at least (gate K7).
 * GENERATED START by osb-camelk-route; the implementer may add tests for further error scopes of FLOW_CARD section 9.
 * Error path as in OSB: either the error output (a queue, mock) receives the message with the correlation header,
 * or (request/reply flows, error_output = "reply") the caller gets an answer, not an exception, with the HTTP status
 * OSB sets (flow-test.json error_http_status, when research names one).
 */
@CamelMainTest(properties = {@@TEST_PROPERTIES@@})
class FlowErrorTest {

    static final Path PARITY = Path.of("src/test/resources/parity");
    static final ObjectMapper JSON = new ObjectMapper();
    static final String REPLY = "reply";

    @Produce("direct:in")
    ProducerTemplate in;

    static JsonNode cfg() throws Exception {
        return JSON.readTree(Path.of("src/test/resources/flow-test.json").toFile());
    }

    CamelContext ctx() {
        return in.getCamelContext();
    }

    MockEndpoint mock(String uri) {
        return ctx().getEndpoint(uri, MockEndpoint.class);
    }

    /** Sends the message and checks it took OSB's error path. */
    void assertErrorPath(String body, Map<String, Object> headers) throws Exception {
        JsonNode cfg = cfg();
        String err = cfg.path("error_output").asText("");
        Assumptions.assumeFalse(err.isEmpty(), "research.json names no error output");
        String corr = cfg.path("correlation_header").asText("traceId");
        for (var it = cfg.path("outputs").fields(); it.hasNext(); ) {
            var o = it.next();
            if (!REPLY.equals(o.getKey())) {
                mock(o.getValue().asText()).expectedMessageCount(o.getKey().equals(err) ? 1 : 0);
            }
        }
        boolean reply = REPLY.equals(err);
        Exchange ex = in.send(e -> {
            e.setPattern(reply ? ExchangePattern.InOut : ExchangePattern.InOnly);
            e.getMessage().setBody(body);
            e.getMessage().setHeaders(new HashMap<>(headers));
        });
        MockEndpoint.assertIsSatisfied(ctx());
        if (reply) {
            assertNull(ex.getException(), "OSB answers the caller on an error, the route must not end with an exception");
            JsonNode status = cfg.path("error_http_status");
            if (status.isInt()) {
                assertEquals(status.asInt(), ex.getMessage().getHeader(Exchange.HTTP_RESPONSE_CODE, Integer.class),
                    "HTTP status of the error reply");
            }
            assertEquals(headers.get(corr), ex.getMessage().getHeader(corr), corr + " must reach the error reply");
        } else {
            var m = mock(cfg.path("outputs").path(err).asText()).getExchanges().get(0).getMessage();
            assertEquals(headers.get(corr), m.getHeader(corr), corr + " must reach the error output");
        }
    }

    @Test
    void unreadablePayloadTakesTheErrorPath() throws Exception {
        Assumptions.assumeTrue("json".equals(cfg().path("payload_format").asText()), "not a JSON flow");
        String corr = cfg().path("correlation_header").asText("traceId");
        assertErrorPath("not json at all", Map.of(corr, "t-invalid"));
    }

    static final String NO_BACKEND = "(none)";

    static Stream<String> backends() throws Exception {
        List<String> b = new ArrayList<>();
        cfg().path("backends").fieldNames().forEachRemaining(b::add);
        return b.isEmpty() ? Stream.of(NO_BACKEND) : b.stream();   // JUnit rejects an empty source: one skipped run instead
    }

    /** OSB error handler of the service: a backend that fails (fault, timeout, HTTP error) takes the error path. */
    @ParameterizedTest(name = "backend {0} fails")
    @MethodSource("backends")
    void backendFaultTakesTheErrorPath(String backend) throws Exception {
        Assumptions.assumeFalse(NO_BACKEND.equals(backend), "the flow calls no backend");
        Path c = firstCase();
        Assumptions.assumeTrue(c != null, "no test case to send");
        mock(cfg().path("backends").path(backend).path("mock").asText())
            .whenAnyExchangeReceived(e -> { throw new IllegalStateException("backend " + backend + " fault (test)"); });
        @SuppressWarnings("unchecked")
        Map<String, Object> headers = JSON.readValue(c.resolve("headers.json").toFile(), Map.class);
        String corr = cfg().path("correlation_header").asText("traceId");
        headers.putIfAbsent(corr, "t-backend-fault");
        assertErrorPath(Files.readString(c.resolve("input.payload")), headers);
    }

    /** HTTP backend answering with an error status: camel-http throws HttpOperationFailedException, which the route
     *  catches on its own (gate K13, without the backend URL in the error text); it must take the same error path. */
    @ParameterizedTest(name = "backend {0} answers HTTP 500")
    @MethodSource("backends")
    void backendHttpErrorTakesTheErrorPath(String backend) throws Exception {
        Assumptions.assumeFalse(NO_BACKEND.equals(backend), "the flow calls no backend");
        Assumptions.assumeTrue(cfg().path("backends").path(backend).path("type").asText("").toLowerCase().startsWith("http"),
            "not an HTTP backend");
        Class<?> hof;
        try {
            hof = Class.forName("org.apache.camel.http.base.HttpOperationFailedException");
        } catch (ClassNotFoundException e) {
            Assumptions.abort("no HTTP component on the classpath");
            return;
        }
        Path c = firstCase();
        Assumptions.assumeTrue(c != null, "no test case to send");
        Exception fault = (Exception) hof.getConstructor(String.class, int.class, String.class, String.class, Map.class, String.class)
            .newInstance("http://backend.test/" + backend + "?q=x", 500, "Internal Server Error", null, Map.of(), "");
        mock(cfg().path("backends").path(backend).path("mock").asText())
            .whenAnyExchangeReceived(e -> { throw fault; });
        @SuppressWarnings("unchecked")
        Map<String, Object> headers = JSON.readValue(c.resolve("headers.json").toFile(), Map.class);
        String corr = cfg().path("correlation_header").asText("traceId");
        headers.putIfAbsent(corr, "t-backend-http-error");
        assertErrorPath(Files.readString(c.resolve("input.payload")), headers);
    }

    static Path firstCase() throws Exception {
        if (!Files.isDirectory(PARITY)) {
            return null;
        }
        try (Stream<Path> s = Files.walk(PARITY)) {
            return s.filter(p -> p.getFileName().toString().equals("input.payload")).map(Path::getParent).sorted()
                .findFirst().orElse(null);
        }
    }

    @Test
    void flowTestConfigIsReadable() throws Exception {
        assertNotNull(cfg().path("outputs"));
        assertFalse(cfg().path("outputs").isEmpty(), "flow-test.json has no outputs");
    }
}
