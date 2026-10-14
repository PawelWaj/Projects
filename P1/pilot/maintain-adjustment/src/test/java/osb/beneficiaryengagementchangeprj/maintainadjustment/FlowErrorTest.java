package osb.beneficiaryengagementchangeprj.maintainadjustment;

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
 *  body and the error headers; the GOSI queue send is retried 3 times, the PPA send is not. Fake values only. */
@CamelMainTest(properties = {"flow.input=direct:in", "out.maintain-adjustment=mock:out-maintain-adjustment",
    "out.ppa-engagement=mock:out-ppa-engagement", "out.maintain-adjustment-error-queue=mock:out-maintain-adjustment-error-queue",
    "retry.maintain-adjustment.delay=0"})
class FlowErrorTest {

    static final String BOTH = "{\"data\":{\"hasPPAEngagement\":true,\"hasGOSIEngagement\":\"true\"}}";
    static final Map<String, Object> HDR = Map.of("traceId", "t-err", "resource", "Contributory Wage", "eventType", "update-approved");

    @Produce("direct:in")
    ProducerTemplate in;

    MockEndpoint mock(String name) {
        return in.getCamelContext().getEndpoint("mock:out-" + name, MockEndpoint.class);
    }

    @Test
    void anyFaultGoesToTheErrorQueueWithOriginalBodyAndHeaders() throws Exception {
        MockEndpoint err = mock("maintain-adjustment-error-queue");
        err.expectedMessageCount(1);
        mock("ppa-engagement").expectedMessageCount(0);
        mock("maintain-adjustment").expectedMessageCount(0);
        in.sendBodyAndHeaders("{not json", HDR);
        MockEndpoint.assertIsSatisfied(in.getCamelContext());
        var m = err.getExchanges().get(0).getMessage();
        assertEquals("{not json", m.getBody(String.class), "error queue gets the original body ($requestDoc)");
        assertNotNull(m.getHeader("errorCode"));
        assertNotNull(m.getHeader("errorMessage"));
        assertNotNull(m.getHeader("debugInfo"));
        assertEquals("t-err", m.getHeader("traceId"));
        assertEquals("Contributory Wage", m.getHeader("resource"));
        assertEquals("update-approved", m.getHeader("eventType"));
    }

    @Test
    void gosiQueueSendIsRetriedThreeTimesThenErrorQueue() throws Exception {
        MockEndpoint gosi = mock("maintain-adjustment");
        gosi.whenAnyExchangeReceived(e -> { throw new IOException("broker down"); });
        mock("maintain-adjustment-error-queue").expectedMessageCount(1);
        mock("ppa-engagement").expectedMessageCount(1);
        in.sendBodyAndHeaders(BOTH, HDR);
        MockEndpoint.assertIsSatisfied(in.getCamelContext());
        assertEquals(4, gosi.getReceivedCounter(), "1 attempt + retry-count 3");
    }

    @Test
    void ppaQueueSendIsNotRetried() throws Exception {
        MockEndpoint ppa = mock("ppa-engagement");
        ppa.whenAnyExchangeReceived(e -> { throw new IOException("broker down"); });
        mock("maintain-adjustment-error-queue").expectedMessageCount(1);
        mock("maintain-adjustment").expectedMessageCount(0);
        in.sendBodyAndHeaders(BOTH, HDR);
        MockEndpoint.assertIsSatisfied(in.getCamelContext());
        assertEquals(1, ppa.getReceivedCounter(), "retry-count 0");
    }

    @Test
    void traceIdIsGeneratedWhenMissingAndBodyIsForwardedUnchanged() throws Exception {
        String body = "{\"data\":{\"hasGOSIEngagement\":\"true\",\"note\":\"a\tb\"}}";
        MockEndpoint gosi = mock("maintain-adjustment");
        gosi.expectedMessageCount(1);
        in.sendBodyAndHeaders(body, Map.of("resource", "Contributory Wage"));
        gosi.assertIsSatisfied();
        var m = gosi.getExchanges().get(0).getMessage();
        assertEquals(body, m.getBody(String.class));
        assertEquals(36, m.getHeader("traceId", String.class).length(), "UUID like fn-bea:uuid()");
    }
}
