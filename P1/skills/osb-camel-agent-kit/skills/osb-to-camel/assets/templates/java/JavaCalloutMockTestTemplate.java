package {{package}}.{{project_pkg}};

import org.apache.camel.CamelContext;
import org.apache.camel.ProducerTemplate;
import org.apache.camel.builder.AdviceWith;
import org.apache.camel.component.mock.MockEndpoint;
import org.apache.camel.test.spring.junit5.CamelSpringBootTest;
import org.apache.camel.test.spring.junit5.UseAdviceWith;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.ActiveProfiles;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * TEMPLATE: Java callout (OSB javaCallout action: archive, class, static method, parameters).
 * Two cases, decided on the flow card (osb-action-mapping.md, javaCallout row):
 *
 *  A. The JAR or its source exists (DG1): the class is ported or put on the classpath UNCHANGED. Test A calls through
 *     the real class with the recorded inputs; its result is part of the oracle (it is OSB's own code).
 *  B. No JAR, no source: the callout is replaced in the route by step id with a stub that returns what the logs show
 *     the callout produced. Test B proves the route around the callout. The flow is NOT done: the record lists the
 *     callout as a blocking finding (osb-action-mapping.md), and gate G7 rejects a stub result as an oracle.
 */
@CamelSpringBootTest
@SpringBootTest(classes = {{ProxyName}}Route.class)
@ActiveProfiles("test")
@UseAdviceWith
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_EACH_TEST_METHOD)   // each test advises the route differently
class {{ProxyName}}JavaCalloutTest {

    @Autowired CamelContext context;
    @Autowired ProducerTemplate template;

    String fixture(String n) throws Exception {
        return Files.readString(Path.of("src/test/resources/parity/{{flow}}").resolve(n));
    }

    /** J-A the real callout class (ported or from the JAR) produces OSB's value for a recorded input. */
    @Test
    void realCalloutProducesOsbValue() throws Exception {
        AdviceWith.adviceWith(context, "{{ProxyName}}", a -> a.replaceFromWith("direct:in"));
        AdviceWith.adviceWith(context, "{{ProxyName}}", a -> a.weaveByToUri("{{output_uri_pattern}}").replace().to("mock:out"));
        context.start();
        MockEndpoint out = context.getEndpoint("mock:out", MockEndpoint.class);
        out.expectedMessageCount(1);

        template.sendBody("direct:in", fixture("{{scenario}}/{{trace}}/input.payload"));

        out.assertIsSatisfied();
        assertThat(out.getExchanges().get(0).getMessage().getHeader("{{callout_result_header}}", String.class))
            .isEqualTo("{{value_seen_in_the_logs}}");
    }

    /** J-B no source: the callout step is stubbed with the value the logs show; proves only the route around it. */
    @Test
    void stubbedCalloutLetsTheRouteContinue() throws Exception {
        AdviceWith.adviceWith(context, "{{ProxyName}}", a -> {
            a.replaceFromWith("direct:in");
            a.weaveById("{{callout_action_id}}").replace()
                .setHeader("{{callout_result_header}}", a.constant("{{value_seen_in_the_logs}}"));   // stub, NOT an oracle
            a.weaveByToUri("{{output_uri_pattern}}").replace().to("mock:out");
        });
        context.start();
        MockEndpoint out = context.getEndpoint("mock:out", MockEndpoint.class);
        out.expectedMessageCount(1);

        template.sendBody("direct:in", fixture("{{scenario}}/{{trace}}/input.payload"));

        out.assertIsSatisfied();
    }
}
