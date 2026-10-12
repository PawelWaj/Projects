package com.example.integration.orderevent;   // TEMPLATE: use the module's package

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.github.tomakehurst.wiremock.junit5.WireMockExtension;
import jakarta.jms.Connection;
import jakarta.jms.Message;
import jakarta.jms.MessageConsumer;
import jakarta.jms.MessageProducer;
import jakarta.jms.Session;
import jakarta.jms.TextMessage;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Iterator;
import java.util.Map;
import java.util.stream.Stream;
import org.apache.qpid.jms.JmsConnectionFactory;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.RegisterExtension;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.activemq.ArtemisContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

/**
 * LEVEL 2, COMPONENT (needs Docker on the build agent). The flow runs in the Spring Boot test context against a REAL
 * Artemis in a container and WireMock for the HTTP backends. Proves what mocks cannot: the broker-side subscription
 * filter (the old proxy's JMS selector), transacted consume, redelivery, and the headers on the wire.
 *
 * TEMPLATE: adapt the names below and the property keys in brokerProperties() to the module's configuration.
 * Check the Artemis image tag and the CLI path against your registry and broker version.
 */
@Testcontainers
@SpringBootTest
class RecordedCasesBrokerIT {

    static final Path FLOW_DIR = Path.of("src/test/resources/parity/order-event-prj-order-event");
    static final String TOPIC = "orderEventsTopic";
    static final String SUBSCRIPTION = "order-event-sub";
    static final String SELECTOR = "(resource='Create Order' OR resource='Cancel Order') AND (eventType='updated')";
    static final String SUCCESS_QUEUE = "InboundOrderEventQueue";
    static final String ERROR_QUEUE = "orderEventErrorQueue";
    static final String CLI = "/var/lib/artemis-instance/bin/artemis";
    private static final ObjectMapper JSON = new ObjectMapper();

    @Container
    static ArtemisContainer artemis = new ArtemisContainer("apache/activemq-artemis:2.37.0").withExposedPorts(61616, 5672, 8161);

    @RegisterExtension
    static WireMockExtension backend = WireMockExtension.newInstance().build();       // stubs: templates/wiremock/*.json

    static String amqpUrl() {
        return "amqp://" + artemis.getHost() + ":" + artemis.getMappedPort(5672);
    }

    @DynamicPropertySource
    static void brokerProperties(DynamicPropertyRegistry r) {                         // TEMPLATE: the module's own keys
        r.add("broker.url", RecordedCasesBrokerIT::amqpUrl);
        r.add("broker.user", artemis::getUser);
        r.add("broker.password", artemis::getPassword);
        r.add("backend.base-url", backend::baseUrl);
    }

    @BeforeAll
    static void createBrokerObjects() throws Exception {                              // same objects as the Git register
        cli("address", "create", "--name", TOPIC, "--multicast", "--no-anycast");
        cli("queue", "create", "--name", SUBSCRIPTION, "--address", TOPIC, "--multicast", "--durable",
            "--preserve-on-no-consumers", "--filter", SELECTOR);
        for (String q : new String[] {SUCCESS_QUEUE, ERROR_QUEUE}) {
            cli("queue", "create", "--name", q, "--address", q, "--anycast", "--durable", "--preserve-on-no-consumers", "--auto-create-address");
        }
    }

    static void cli(String... args) throws Exception {
        String[] cmd = Stream.concat(Stream.of(CLI), Stream.concat(Stream.of(args),
            Stream.of("--user", artemis.getUser(), "--password", artemis.getPassword(), "--silent"))).toArray(String[]::new);
        artemis.execInContainer(cmd);
    }

    static Stream<Path> recordedCases() throws Exception {
        try (Stream<Path> files = Files.walk(FLOW_DIR)) {
            return files.filter(p -> p.getFileName().toString().equals("input.payload")).map(Path::getParent).sorted().toList().stream();
        }
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("recordedCases")
    void recordedCaseArrivesOnTheExpectedQueue(Path fx) throws Exception {
        JsonNode expected = JSON.readTree(fx.resolve("expected.json").toFile());
        JsonNode headers = JSON.readTree(fx.resolve("headers.json").toFile());
        String traceId = headers.get("traceId").asText();
        String queue = "success".equals(expected.get("outcome").asText()) ? SUCCESS_QUEUE : ERROR_QUEUE;
        try (Connection c = new JmsConnectionFactory(artemis.getUser(), artemis.getPassword(), amqpUrl()).createConnection()) {
            c.start();
            Session s = c.createSession(false, Session.AUTO_ACKNOWLEDGE);
            MessageProducer p = s.createProducer(s.createTopic(TOPIC));
            TextMessage m = s.createTextMessage(Files.readString(fx.resolve("input.payload")));
            for (Iterator<Map.Entry<String, JsonNode>> it = headers.fields(); it.hasNext(); ) {
                Map.Entry<String, JsonNode> e = it.next();
                m.setStringProperty(e.getKey(), e.getValue().asText());
            }
            p.send(m);
            MessageConsumer consumer = s.createConsumer(s.createQueue(queue), "traceId = '" + traceId + "'");
            Message out = consumer.receive(15_000);
            assertThat(out).as("message on " + queue).isNotNull();
            for (JsonNode h : expected.get("expected_headers")) {
                assertThat(out.propertyExists(h.asText())).as("header " + h.asText()).isTrue();
            }
        }
    }

    @Test
    void messagesOutsideTheSelectorAreDropped() throws Exception {                    // OSB never logged these: from the proxy config
        try (Connection c = new JmsConnectionFactory(artemis.getUser(), artemis.getPassword(), amqpUrl()).createConnection()) {
            c.start();
            Session s = c.createSession(false, Session.AUTO_ACKNOWLEDGE);
            TextMessage m = s.createTextMessage("{}");
            m.setStringProperty("resource", "Create Order");
            m.setStringProperty("eventType", "created");
            m.setStringProperty("traceId", "negative-1");
            s.createProducer(s.createTopic(TOPIC)).send(m);
            for (String q : new String[] {SUCCESS_QUEUE, ERROR_QUEUE}) {
                assertThat(s.createConsumer(s.createQueue(q), "traceId = 'negative-1'").receive(3_000)).as(q).isNull();
            }
        }
    }
}
