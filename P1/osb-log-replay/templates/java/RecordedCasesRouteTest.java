package com.example.integration.orderevent;   // TEMPLATE: use the module's package

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;
import java.util.stream.Stream;
import org.apache.camel.CamelContext;
import org.apache.camel.EndpointInject;
import org.apache.camel.Exchange;
import org.apache.camel.ProducerTemplate;
import org.apache.camel.builder.AdviceWith;
import org.apache.camel.component.mock.MockEndpoint;
import org.apache.camel.test.spring.junit5.CamelSpringBootTest;
import org.apache.camel.test.spring.junit5.UseAdviceWith;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;

/**
 * LEVEL 1, UNIT (no Docker). Replays every recorded OSB case through the route with all boundaries mocked:
 * the input subscription becomes direct:in, the output queues become mock endpoints, HTTP backends become mocks.
 *
 * Fixtures: src/test/resources/parity/<flow>/<scenario>/<trace>/ written by osb-log-replay/tools/fixtures_from_traces.py
 *   input.payload, headers.json, expected.json, optional expected-output.xml (from the ORIGINAL XQuery, golden test).
 *
 * TEMPLATE: adapt ROUTE_ID, FLOW_DIR and the three endpoint patterns to the route; nothing else should need editing.
 */
@CamelSpringBootTest
@SpringBootTest
@UseAdviceWith
class RecordedCasesRouteTest {

    static final String ROUTE_ID = "order-event";                                     // routeId of the migrated proxy
    static final Path FLOW_DIR = Path.of("src/test/resources/parity/order-event-prj-order-event");
    static final String SUCCESS_URI = "amqp:queue:InboundOrderEventQueue*";           // patterns of the real endpoints
    static final String ERROR_URI = "amqp:queue:orderEventErrorQueue*";
    static final String BACKEND_URI = "http*";                                        // remove if the flow calls no backend

    private static final ObjectMapper JSON = new ObjectMapper();

    @Autowired CamelContext context;
    @Autowired ProducerTemplate producer;
    @EndpointInject("mock:success") MockEndpoint success;
    @EndpointInject("mock:error") MockEndpoint error;
    @EndpointInject("mock:backend") MockEndpoint backend;

    @BeforeEach
    void mockTheBoundaries() throws Exception {
        if (context.isStarted()) {
            MockEndpoint.resetMocks(context);
            return;
        }
        AdviceWith.adviceWith(context, ROUTE_ID, r -> {
            r.replaceFromWith("direct:in");                                           // instead of the topic subscription
            r.weaveByToUri(SUCCESS_URI).replace().to("mock:success");
            r.weaveByToUri(ERROR_URI).replace().to("mock:error");
            r.weaveByToUri(BACKEND_URI).replace().to("mock:backend");                 // canned reply set per test if needed
        });
        context.start();
    }

    static Stream<Path> recordedCases() throws Exception {
        try (Stream<Path> files = Files.walk(FLOW_DIR)) {
            return files.filter(p -> p.getFileName().toString().equals("input.payload")).map(Path::getParent).sorted().toList().stream();
        }
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("recordedCases")
    void replaysRecordedCase(Path fx) throws Exception {
        JsonNode expected = JSON.readTree(fx.resolve("expected.json").toFile());
        Map<String, Object> headers = new HashMap<>();
        JSON.readTree(fx.resolve("headers.json").toFile()).fields().forEachRemaining(e -> headers.put(e.getKey(), e.getValue().asText()));
        boolean ok = "success".equals(expected.get("outcome").asText());
        MockEndpoint target = ok ? success : error;
        target.expectedMessageCount(1);
        (ok ? error : success).expectedMessageCount(0);

        producer.sendBodyAndHeaders("direct:in", Files.readString(fx.resolve("input.payload")), headers);

        MockEndpoint.assertIsSatisfied(context);
        Exchange out = target.getReceivedExchanges().get(0);
        for (JsonNode h : expected.get("expected_headers")) {                         // e.g. errorCode, errorMessage, traceId
            assertThat(out.getMessage().getHeaders()).containsKey(h.asText());
        }
        Path golden = fx.resolve("expected-output.xml");
        if (ok && Files.exists(golden)) {                                              // oracle = original transform, never this code
            org.xmlunit.assertj3.XmlAssert.assertThat(out.getMessage().getBody(String.class))
                .and(Files.readString(golden)).ignoreWhitespace().areIdentical();
        }
    }
}
