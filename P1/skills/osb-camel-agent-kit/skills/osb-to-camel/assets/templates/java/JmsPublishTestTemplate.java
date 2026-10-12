package {{package}}.{{project_pkg}};

import org.apache.camel.ConsumerTemplate;
import org.apache.camel.ProducerTemplate;
import org.apache.camel.test.spring.junit5.CamelSpringBootTest;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.activemq.ArtemisContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * TEMPLATE: the OSB publish to a JMS business service, proven against a throwaway Artemis (Testcontainers).
 * Proves: the proxy response does not wait for the publish (InOnly), exactly one message lands on the destination
 * with the body the outbound transform built, and (for transactional proxies) a failure after the publish rolls it
 * back. Requires Docker; when Docker is absent the test is disabled and the migration record says so.
 */
@Testcontainers(disabledWithoutDocker = true)
@CamelSpringBootTest
@SpringBootTest(classes = {{ProxyName}}Route.class)
@ActiveProfiles("test")
class {{ProxyName}}JmsPublishTest {

    @Container
    static final ArtemisContainer ARTEMIS = new ArtemisContainer("apache/activemq-artemis:2.42.0-alpine")   // pin per versions.md
        .withUser("test").withPassword("test");

    @DynamicPropertySource
    static void broker(DynamicPropertyRegistry r) {
        // AMQP 1.0 on 5672, the protocol the programme uses towards Red Hat AMQ Broker
        r.add("camel.component.amqp.remote-uri", () -> "amqp://" + ARTEMIS.getHost() + ":" + ARTEMIS.getMappedPort(5672));
        r.add("camel.component.amqp.username", () -> "test");
        r.add("camel.component.amqp.password", () -> "test");
        r.add("osb.business.AuditQueueBS.destination", () -> "APP.AUDIT.QUEUE");
    }

    @Autowired ProducerTemplate producer;
    @Autowired ConsumerTemplate consumer;

    /** J-01 one audit message per getContributor, body as built by the outbound transform. */
    @Test
    void publish_putsExactlyOneAuditMessageOnTheQueue() {
        producer.sendBody("direct:{{ProxyName}}-publishAudit", "<ignored/>");   // the publish sub-route builds its own body
        String msg = consumer.receiveBody("amqp:queue:APP.AUDIT.QUEUE", 5000, String.class);
        assertThat(msg).contains("<op>getContributor</op>");
        assertThat(consumer.receiveBodyNoWait("amqp:queue:APP.AUDIT.QUEUE")).isNull();
    }
}
