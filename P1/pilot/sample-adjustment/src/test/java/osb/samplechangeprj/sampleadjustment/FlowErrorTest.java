package osb.samplechangeprj.sampleadjustment;

import org.apache.camel.Produce;
import org.apache.camel.ProducerTemplate;
import org.apache.camel.component.mock.MockEndpoint;
import org.apache.camel.test.main.junit5.CamelMainTest;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;

/** Error handler of the OSB pipeline (FLOW_CARD.md section 7): every failure reaches the error queue with the original
 *  body and the error headers; the main queue send is retried 3 times, the partner send is not. Fake values only. */
@CamelMainTest(properties = {"flow.input=direct:in", "out.sample-adjustment=mock:out-sample-adjustment",
    "out.partner-engagement=mock:out-partner-engagement", "out.sample-adjustment-error-queue=mock:out-sample-adjustment-error-queue",
    "retry.sample-adjustment.delay=0"})
class FlowErrorTest {

    static final String BOTH = "{\"data\":{\"hasPartnerEngagement\":true,\"hasMainEngagement\":\"true\"}}";
    static final Map<String, Object> HDR = Map.of("traceId", "t-err", "resource", "Sample Resource", "eventType", "approved");

    @Produce("direct:in")
    ProducerTemplate in;

    MockEndpoint mock(String name) {
        return in.getCamelContext().getEndpoint("mock:out-" + name, MockEndpoint.class);
    }

    @Test
    void anyFaultGoesToTheErrorQueueWithOriginalBodyAndHeaders() throws Exception {
        MockEndpoint err = mock("sample-adjustment-error-queue");
        err.expectedMessageCount(1);
        mock("partner-engagement").expectedMessageCount(0);
        mock("sample-adjustment").expectedMessageCount(0);
        in.sendBodyAndHeaders("{not json", HDR);
        MockEndpoint.assertIsSatisfied(in.getCamelContext());
        var m = err.getExchanges().get(0).getMessage();
        assertEquals("{not json", m.getBody(String.class), "error queue gets the original body ($requestDoc)");
        assertNotNull(m.getHeader("errorCode"));
        assertNotNull(m.getHeader("errorMessage"));
        assertNotNull(m.getHeader("debugInfo"));
        assertEquals("t-err", m.getHeader("traceId"));
        assertEquals("Sample Resource", m.getHeader("resource"));
        assertEquals("approved", m.getHeader("eventType"));
    }

    @Test
    void mainQueueSendIsRetriedThreeTimesThenErrorQueue() throws Exception {
        MockEndpoint main = mock("sample-adjustment");
        main.whenAnyExchangeReceived(e -> { throw new IOException("broker down"); });
        mock("sample-adjustment-error-queue").expectedMessageCount(1);
        mock("partner-engagement").expectedMessageCount(1);
        in.sendBodyAndHeaders(BOTH, HDR);
        MockEndpoint.assertIsSatisfied(in.getCamelContext());
        assertEquals(4, main.getReceivedCounter(), "1 attempt + retry-count 3");
    }

    @Test
    void partnerQueueSendIsNotRetried() throws Exception {
        MockEndpoint partner = mock("partner-engagement");
        partner.whenAnyExchangeReceived(e -> { throw new IOException("broker down"); });
        mock("sample-adjustment-error-queue").expectedMessageCount(1);
        mock("sample-adjustment").expectedMessageCount(0);
        in.sendBodyAndHeaders(BOTH, HDR);
        MockEndpoint.assertIsSatisfied(in.getCamelContext());
        assertEquals(1, partner.getReceivedCounter(), "retry-count 0");
    }

    @Test
    void traceIdIsGeneratedWhenMissingAndBodyIsForwardedUnchanged() throws Exception {
        String body = "{\"data\":{\"hasMainEngagement\":\"true\",\"note\":\"a\tb\"}}";
        MockEndpoint main = mock("sample-adjustment");
        main.expectedMessageCount(1);
        in.sendBodyAndHeaders(body, Map.of("resource", "Sample Resource"));
        main.assertIsSatisfied();
        var m = main.getExchanges().get(0).getMessage();
        assertEquals(body, m.getBody(String.class));
        assertEquals(36, m.getHeader("traceId", String.class).length(), "UUID like fn-bea:uuid()");
    }
}
