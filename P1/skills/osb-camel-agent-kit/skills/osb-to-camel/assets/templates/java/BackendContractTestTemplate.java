package {{package}}.{{project_pkg}};

import com.github.tomakehurst.wiremock.junit5.WireMockExtension;
import org.apache.camel.ProducerTemplate;
import org.apache.camel.component.cxf.common.message.CxfConstants;
import org.apache.camel.test.spring.junit5.CamelSpringBootTest;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.RegisterExtension;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;

import static com.github.tomakehurst.wiremock.client.WireMock.*;
import static com.github.tomakehurst.wiremock.core.WireMockConfiguration.wireMockConfig;
import static org.assertj.core.api.Assertions.assertThat;

/**
 * TEMPLATE: backend contract test. The route runs with its real CXF/HTTP producers against WireMock, which plays the
 * business services. Proves (a) the request the route sends, (b) timeout + retry behaviour as the business service
 * was configured in OSB, (c) that application faults are NOT retried (retry-application-errors=false),
 * (d) header propagation. Stub bodies come from fixtures/{{flow}}/backend/<BusinessService>/ (schema-derived or
 * recorded; the parity test reuses the recorded ones).
 */
@CamelSpringBootTest
@SpringBootTest(classes = {{ProxyName}}Route.class)
@ActiveProfiles("test")
class {{ProxyName}}BackendContractTest {

    @RegisterExtension
    static WireMockExtension backends = WireMockExtension.newInstance().options(wireMockConfig().dynamicPort().usingFilesUnderDirectory("src/test/resources/fixtures/{{flow}}/backend")).build();

    static final Map<String, String> NS = Map.of("mem", "http://example.com/member/v2", "ns", "http://example.com/integration/contributor/v1");

    @DynamicPropertySource
    static void pointBackendsAtWireMock(DynamicPropertyRegistry r) {
        r.add("osb.business.ContributorCoreBS.url", () -> backends.baseUrl() + "/ContributorService");
        r.add("osb.business.MemberLookupBS.url", () -> backends.baseUrl() + "/MemberLookup/v2");
        r.add("osb.business.ContributorCoreBS.timeout", () -> "1000");        // 1 s in the test, 30 s in OSB: same shape
        r.add("osb.business.ContributorCoreBS.retry-count", () -> "1");       // OSB retry-count 1
        r.add("osb.business.ContributorCoreBS.retry-interval", () -> "100");
    }

    @Autowired ProducerTemplate template;

    String fixture(String n) throws Exception { return Files.readString(Path.of("src/test/resources/fixtures/{{flow}}").resolve(n)); }

    /** C-01 the request to the core backend carries the transformed body and the correlation header. */
    @Test
    void coreReceivesTransformedRequest_withCorrelationHeader() throws Exception {
        backends.stubFor(post(urlPathEqualTo("/MemberLookup/v2")).withHeader("SOAPAction", containing("lookupMember"))
            .willReturn(okXml(fixture("backend/MemberLookupBS/lookupMember-active-response.xml"))));
        backends.stubFor(post(urlPathEqualTo("/ContributorService")).withHeader("SOAPAction", containing("getContributor"))
            .willReturn(okXml(fixture("backend/ContributorCoreBS/getContributor-response.xml"))));

        template.sendBodyAndHeaders("cxf:bean:{{proxyName}}Endpoint?dataFormat=PAYLOAD", fixture("01-getContributor-active-input.xml"),
            Map.of(CxfConstants.OPERATION_NAME, "getContributor", "X-Correlation-Id", "test-correlation"));

        backends.verify(postRequestedFor(urlPathEqualTo("/ContributorService"))
            .withHeader("X-Correlation-Id", equalTo("test-correlation"))
            .withRequestBody(matchingXPath("//ns:getContributorRequest[ns:contributorId='test-contributorId']", NS)));
    }

    /** C-02 timeout on the core backend: exactly retry-count + 1 attempts, then the OSB-380001 fault. */
    @Test
    void coreTimeout_isRetriedOnce_thenFaults() throws Exception {
        backends.stubFor(post(urlPathEqualTo("/MemberLookup/v2")).willReturn(okXml(fixture("backend/MemberLookupBS/lookupMember-active-response.xml"))));
        backends.stubFor(post(urlPathEqualTo("/ContributorService")).willReturn(okXml("<x/>").withFixedDelay(1500)));

        var exchange = template.send("cxf:bean:{{proxyName}}Endpoint?dataFormat=PAYLOAD", e -> {
            e.getMessage().setBody(fixture("01-getContributor-active-input.xml"));
            e.getMessage().setHeader(CxfConstants.OPERATION_NAME, "getContributor");
        });

        backends.verify(exactly(2), postRequestedFor(urlPathEqualTo("/ContributorService")));
        assertThat(exchange.getMessage().getHeader("osb.fault.errorCode", String.class)).isEqualTo("OSB-380001");
    }

    /** C-03 a SOAP fault from the backend is an application error: no retry (retry-application-errors=false). */
    @Test
    void coreSoapFault_isNotRetried() throws Exception {
        backends.stubFor(post(urlPathEqualTo("/MemberLookup/v2")).willReturn(okXml(fixture("backend/MemberLookupBS/lookupMember-active-response.xml"))));
        backends.stubFor(post(urlPathEqualTo("/ContributorService")).willReturn(aResponse().withStatus(500)
            .withHeader("Content-Type", "text/xml").withBody(fixture("backend/ContributorCoreBS/soap-fault-response.xml"))));

        template.send("cxf:bean:{{proxyName}}Endpoint?dataFormat=PAYLOAD", e -> {
            e.getMessage().setBody(fixture("01-getContributor-active-input.xml"));
            e.getMessage().setHeader(CxfConstants.OPERATION_NAME, "getContributor");
        });

        backends.verify(exactly(1), postRequestedFor(urlPathEqualTo("/ContributorService")));
    }
}
