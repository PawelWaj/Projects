package {{package}}.{{project_pkg}};

import org.apache.camel.CamelContext;
import org.apache.camel.ExchangePattern;
import org.apache.camel.ProducerTemplate;
import org.apache.camel.builder.AdviceWith;
import org.apache.camel.component.cxf.common.message.CxfConstants;
import org.apache.camel.component.mock.MockEndpoint;
import org.apache.camel.test.spring.junit5.CamelSpringBootTest;
import org.apache.camel.test.spring.junit5.UseAdviceWith;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.ActiveProfiles;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;

import org.xmlunit.assertj3.XmlAssert;

import static org.assertj.core.api.Assertions.assertThat;
// XMLUnit's XmlAssert.assertThat(Object) is NOT statically imported next to AssertJ's assertThat(String): for a String
// argument Java resolves to AssertJ's overload and the XML methods (and/areSimilar) do not compile. Qualify it.

/**
 * TEMPLATE: route test for one migrated OSB proxy. One @Test per row of the flow card's test matrix of type "route".
 * Everything outside the route is a mock: the CXF inbound is replaced by direct:in, and every backend call is replaced
 * BY ITS STEP ID (the OSB action id the route carries), so the test does not depend on how the endpoint URI is built.
 * No hostname of any real system appears here; that is the point.
 */
@CamelSpringBootTest
@SpringBootTest(classes = {{ProxyName}}Route.class)
@ActiveProfiles("test")
@UseAdviceWith
class {{ProxyName}}RouteTest {

    static final Path FIXTURES = Path.of("src/test/resources/fixtures/{{flow}}");

    @Autowired CamelContext context;
    @Autowired ProducerTemplate template;

    MockEndpoint core;      // replaces _ActionId-15 / _ActionId-16 (route node to ContributorCoreBS)
    MockEndpoint member;    // replaces _ActionId-4 (service callout to MemberLookupBS)
    MockEndpoint audit;     // replaces publish-audit (amqp)

    @BeforeEach
    void adviceRoutes() throws Exception {
        AdviceWith.adviceWith(context, "{{ProxyName}}", a -> a.replaceFromWith("direct:in"));
        AdviceWith.adviceWith(context, "{{ProxyName}}-getContributor", a -> {
            a.weaveById("_ActionId-4").replace().to("mock:member");
            a.weaveById("_ActionId-15").replace().to("mock:core");
            a.weaveById("_ActionId-1").replace().log("validator skipped: covered by the schema test");   // isolate the logic
        });
        AdviceWith.adviceWith(context, "{{ProxyName}}-updateContributor", a -> a.weaveById("_ActionId-16").replace().to("mock:core"));
        AdviceWith.adviceWith(context, "{{ProxyName}}-publishAudit", a -> a.weaveById("publish-audit").replace().to("mock:audit"));
        context.start();
        core = context.getEndpoint("mock:core", MockEndpoint.class);
        member = context.getEndpoint("mock:member", MockEndpoint.class);
        audit = context.getEndpoint("mock:audit", MockEndpoint.class);
    }

    String fixture(String name) throws Exception { return Files.readString(FIXTURES.resolve(name)); }

    /** T-01 getContributor, member ACTIVE: transform applied, bare payload routed to core, audit published once, InOnly. */
    @Test
    void getContributor_activeMember_isTransformedRoutedAndAudited() throws Exception {
        member.whenAnyExchangeReceived(e -> e.getMessage().setBody(fixture("backend/MemberLookupBS/lookupMember-active-response.xml")));
        core.whenAnyExchangeReceived(e -> e.getMessage().setBody(fixture("backend/ContributorCoreBS/getContributor-response.xml")));
        core.expectedMessageCount(1);
        core.message(0).header("X-Correlation-Id").isEqualTo("test-correlation");
        audit.expectedMessageCount(1);
        audit.message(0).exchangePattern().isEqualTo(ExchangePattern.InOnly);

        String reply = template.requestBodyAndHeaders("direct:in", fixture("01-getContributor-active-input.xml"),
            Map.of(CxfConstants.OPERATION_NAME, "getContributor", "X-Correlation-Id", "test-correlation"), String.class);

        MockEndpoint.assertIsSatisfied(context);
        String sentToCore = core.getExchanges().get(0).getMessage().getBody(String.class);
        XmlAssert.assertThat(sentToCore).and(fixture("01-getContributor-active-expected-core-request.xml")).ignoreWhitespace().ignoreComments().areSimilar();
        assertThat(sentToCore).doesNotContain("<Body>");                         // the wrapper never reaches a backend
        XmlAssert.assertThat(reply).and(fixture("backend/ContributorCoreBS/getContributor-response.xml")).ignoreWhitespace().areSimilar();
    }

    /** T-02 getContributor, member INACTIVE: raise error AMN-4001, core never called, fault reply through the original XSLT. */
    @Test
    void getContributor_inactiveMember_raisesAmn4001_andDoesNotRouteToCore() throws Exception {
        member.whenAnyExchangeReceived(e -> e.getMessage().setBody(fixture("backend/MemberLookupBS/lookupMember-inactive-response.xml")));
        core.expectedMessageCount(0);
        audit.expectedMessageCount(0);

        var exchange = template.send("direct:in", e -> {
            e.getMessage().setBody(fixture("01-getContributor-active-input.xml"));
            e.getMessage().setHeader(CxfConstants.OPERATION_NAME, "getContributor");
        });

        MockEndpoint.assertIsSatisfied(context);
        assertThat(exchange.getMessage().getHeader("osb.fault.errorCode", String.class)).isEqualTo("AMN-4001");
        XmlAssert.assertThat(exchange.getMessage().getBody(String.class)).and(fixture("02-fault-amn4001-expected.xml")).ignoreWhitespace().areSimilar();
    }

    /** T-03 updateContributor: pass-through to core with the right operation and a bare payload. */
    @Test
    void updateContributor_isRoutedToCore_withOperationHeader() throws Exception {
        core.expectedMessageCount(1);
        core.message(0).header(CxfConstants.OPERATION_NAME).isEqualTo("updateContributor");
        template.sendBodyAndHeader("direct:in", fixture("03-updateContributor-input.xml"), CxfConstants.OPERATION_NAME, "updateContributor");
        MockEndpoint.assertIsSatisfied(context);
        assertThat(core.getExchanges().get(0).getMessage().getBody(String.class)).doesNotContain("<Body>");
    }

    /** T-04 unknown operation: OSB-380002 fault, nothing called. */
    @Test
    void unknownOperation_isRejected() throws Exception {
        core.expectedMessageCount(0);
        var exchange = template.send("direct:in", e -> {
            e.getMessage().setBody(fixture("03-updateContributor-input.xml"));
            e.getMessage().setHeader(CxfConstants.OPERATION_NAME, "deleteContributor");
        });
        MockEndpoint.assertIsSatisfied(context);
        assertThat(exchange.getMessage().getHeader("osb.fault.errorCode", String.class)).isEqualTo("OSB-380002");
    }

    /** T-05 service error handler: a backend failure maps through the original fault XSLT and alerts once. */
    @Test
    void coreFailure_isMappedByTheOriginalFaultXslt() throws Exception {
        member.whenAnyExchangeReceived(e -> e.getMessage().setBody(fixture("backend/MemberLookupBS/lookupMember-active-response.xml")));
        core.whenAnyExchangeReceived(e -> { throw new java.net.ConnectException("core down"); });
        var exchange = template.send("direct:in", e -> {
            e.getMessage().setBody(fixture("01-getContributor-active-input.xml"));
            e.getMessage().setHeader(CxfConstants.OPERATION_NAME, "getContributor");
        });
        assertThat(exchange.getMessage().getHeader("osb.fault.errorCode", String.class)).isEqualTo("OSB-380001");
        assertThat(exchange.getMessage().getBody(String.class)).contains("Fault");
    }
}
