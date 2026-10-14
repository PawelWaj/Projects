package pilot.maintainadjustment;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.apache.camel.EndpointInject;
import org.apache.camel.Produce;
import org.apache.camel.ProducerTemplate;
import org.apache.camel.component.mock.MockEndpoint;
import org.apache.camel.test.main.junit5.CamelMainTest;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;

/**
 * L1 parity test of the YAML route with Camel mock endpoints (no broker, no cluster, Maven only).
 * Every case folder under src/test/resources/parity/** comes from task 1 (real messages from Splunk, masked):
 *   input.payload  the message OSB received      headers.json   resource, traceId
 *   expected.json  outcome + destination         expected-output.json   the original XQuery result (task 2)
 * On the VDI: copy task1/fixtures/parity/* into src/test/resources/parity/ and run mvn test.
 */
@CamelMainTest(properties = {"flow.input=direct:in", "flow.success=mock:success", "flow.error=mock:error"})
class MaintainAdjustmentParityTest {

    static final Path PARITY = Path.of("src/test/resources/parity");
    static final ObjectMapper JSON = new ObjectMapper();

    @EndpointInject("mock:success")
    MockEndpoint success;

    @EndpointInject("mock:error")
    MockEndpoint error;

    @Produce("direct:in")
    ProducerTemplate in;

    static Stream<Arguments> cases() throws Exception {
        if (!Files.isDirectory(PARITY)) {
            return Stream.empty();
        }
        try (Stream<Path> s = Files.walk(PARITY)) {
            return s.filter(p -> p.getFileName().toString().equals("input.payload")).map(Path::getParent).sorted()
                .map(c -> Arguments.of(PARITY.relativize(c).toString(), c)).toList().stream();
        }
    }

    @Test
    void caseFoldersArePresent() throws Exception {
        assertFalse(cases().toList().isEmpty(), "no test cases: copy task1/fixtures/parity/* into " + PARITY);
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("cases")
    void sameOutcomeAndCorrelationAsOsb(String name, Path c) throws Exception {
        JsonNode expected = JSON.readTree(c.resolve("expected.json").toFile());
        @SuppressWarnings("unchecked")
        Map<String, Object> headers = JSON.readValue(c.resolve("headers.json").toFile(), Map.class);
        boolean ok = "success".equals(expected.path("outcome").asText());
        MockEndpoint target = ok ? success : error;
        target.expectedMessageCount(1);
        (ok ? error : success).expectedMessageCount(0);

        in.sendBodyAndHeaders(Files.readString(c.resolve("input.payload")), headers);

        MockEndpoint.assertIsSatisfied(success, error);
        assertEquals(expected.path("correlation").asText(),
            target.getExchanges().get(0).getMessage().getHeader("traceId", String.class), "traceId must be carried through");
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("cases")
    void bodyEqualsOriginalXQueryResult(String name, Path c) throws Exception {
        Path golden = c.resolve("expected-output.json");
        Assumptions.assumeTrue(Files.exists(golden), "expected output pending: original XQuery result comes from task 2");
        success.expectedMessageCount(1);
        @SuppressWarnings("unchecked")
        Map<String, Object> headers = JSON.readValue(c.resolve("headers.json").toFile(), Map.class);
        in.sendBodyAndHeaders(Files.readString(c.resolve("input.payload")), headers);
        success.assertIsSatisfied();
        assertEquals(JSON.readTree(golden.toFile()),
            JSON.readTree(success.getExchanges().get(0).getMessage().getBody(String.class)));
    }

    @Test
    void invalidPayloadGoesToErrorWithCode() throws Exception {
        error.expectedMessageCount(1);
        success.expectedMessageCount(0);
        in.sendBodyAndHeaders("not json at all", Map.of("traceId", "t-invalid", "resource", "Contributory Wage"));
        MockEndpoint.assertIsSatisfied(success, error);
        var m = error.getExchanges().get(0).getMessage();
        assertEquals("INVALID_PAYLOAD", m.getHeader("errorCode"));
        assertNotNull(m.getHeader("errorMessage"));
        assertEquals("t-invalid", m.getHeader("traceId"));
    }

    @Test
    void payloadsOsbAcceptsAreAccepted() throws Exception {
        success.expectedMessageCount(2);
        error.expectedMessageCount(0);
        String json = "{\"data\":{\"businessTransaction\":\"MANAGE_WAGE\",\"note\":\"a\tb\"}}";   // raw tab inside a string
        in.sendBodyAndHeaders(json, Map.of("traceId", "t-ctrl"));
        in.sendBodyAndHeaders(json + " ]tail", Map.of("traceId", "t-trailing"));                // text after the JSON
        MockEndpoint.assertIsSatisfied(success, error);
        assertEquals("MANAGE_WAGE", success.getExchanges().get(0).getMessage().getHeader("businessTransaction"));
    }
}
