package {{package}}.{{project_pkg}};

import {{package}}.osb.OsbSupport.OsbBodyWrapper;
import {{package}}.osb.OsbSupport.OsbFaultException;
import {{package}}.osb.OsbSupport.OsbFaultProcessor;
import {{package}}.osb.OsbSupport.OsbXQuery;
import org.apache.camel.ExchangePattern;
import org.apache.camel.LoggingLevel;
import org.apache.camel.builder.RouteBuilder;
import org.apache.camel.component.cxf.common.message.CxfConstants;
import org.springframework.stereotype.Component;

import java.net.ConnectException;
import java.net.SocketTimeoutException;
import java.util.Map;

/**
 * TEMPLATE for one migrated OSB proxy service. Replace the {{placeholders}}; keep the structure.
 *
 * Shape (why it looks like this):
 *  - one inbound route = the OSB proxy; it dispatches by WSDL operation like the OSB operational branch;
 *  - one direct: sub-route per operation = the OSB pipeline pair (request stages, route node, response stages);
 *  - every backend endpoint is a {{placeholder}}; every retry/timeout comes from configuration; the test replaces the
 *    endpoints with mocks (AdviceWith) by their step ids;
 *  - OSB expressions run through OsbXQuery with OSB variable semantics ($body, $memberResp, $inbound) and are copied
 *    from the pipeline XML verbatim, so the card's action ids map to lines here one to one;
 *  - $body handling: wrap() once at the inbound, unwrap() BEFORE EVERY backend call, rewrap() after a request-response
 *    call so the response pipeline sees the backend response as $body, unwrap() at the reply;
 *  - error handlers at the scope the flow card decided: stage (doTry), route node (onException on the backend segment),
 *    service (route-level onException that runs the OSB error pipeline).
 *
 * Route ids and step ids are the OSB names and action ids, so logs, metrics, tests and the migration record speak the
 * same language as the export.
 */
@Component
public class {{ProxyName}}Route extends RouteBuilder {

    // the pipeline's userNsDecl list, copied from the pipeline XML (<con:context>)
    static final Map<String, String> NS = Map.of(
        "ns", "http://example.com/integration/contributor/v1",
        "mem", "http://example.com/member/v2",
        "ctx", "http://www.bea.com/wli/sb/context",
        "tp", "http://www.bea.com/wli/sb/transports",
        "http", "http://www.bea.com/wli/sb/transports/http");

    // OSB variable names kept as exchange property names; they must not leak onto the wire, so never headers
    static final String P_CONTRIBUTOR_ID = "contributorId";
    static final String P_MEMBER_REQ = "memberReq";
    static final String P_MEMBER_RESP = "memberResp";

    // backend endpoints; address, timeouts and WSDL come from configuration, never literals
    static final String EP_CORE = "cxf:{{osb.business.ContributorCoreBS.url}}?wsdlURL=classpath:osb/{{project}}/WSDL/ContributorEnquiry.wsdl"
        + "&serviceName={http://example.com/integration/contributor/v1}ContributorEnquiryService&portName={http://example.com/integration/contributor/v1}ContributorEnquiryPort"
        + "&dataFormat=PAYLOAD&properties.org.apache.cxf.transport.http.receiveTimeout={{osb.business.ContributorCoreBS.timeout}}";
    static final String EP_MEMBER = "cxf:{{osb.business.MemberLookupBS.url}}?wsdlURL=classpath:osb/{{project}}/WSDL/MemberLookup.wsdl"
        + "&serviceName={http://example.com/member/v2}MemberLookupService&portName={http://example.com/member/v2}MemberLookupPort"
        + "&dataFormat=PAYLOAD&properties.org.apache.cxf.transport.http.receiveTimeout={{osb.business.MemberLookupBS.timeout}}";
    static final String EP_AUDIT = "amqp:queue:{{osb.business.AuditQueueBS.destination}}";

    @Override
    public void configure() {

        // --- service-level error handler = the OSB error pipeline "ServiceErrorHandler" -----------------------------
        onException(Exception.class)
            .handled(true)
            .process(new OsbFaultProcessor()).id("fault-context")                 // $fault/* -> headers + <ctx:fault> body
            .to("xslt-saxon:classpath:osb/{{project}}/Transform/ContributorFault.xsl").id("_ActionId-13")   // original fault XSLT, unchanged
            .log(LoggingLevel.WARN, "{{logger}}", "ALERT OpsAlert major: ${header.osb.fault.errorCode}").id("_ActionId-14")
            .to("micrometer:counter:osb.alert?tags=flow={{ProxyName}},severity=major")
            .process(OsbFaultProcessor::replyWithSoapFault).id("_ActionId-reply-error");   // OSB reply isErrorReply=true

        // --- backend retry = business service retry-count / retry-interval, transport failures only (retry-application-errors=false)
        onException(ConnectException.class, SocketTimeoutException.class)
            .onWhen(exchangeProperty("osb.backend").isEqualTo("ContributorCoreBS"))
            .maximumRedeliveries("{{osb.business.ContributorCoreBS.retry-count}}")
            .redeliveryDelay("{{osb.business.ContributorCoreBS.retry-interval}}")
            .useOriginalMessage().logRetryAttempted(true)
            .handled(false);                                                      // after the last retry the service handler maps the fault

        // --- inbound = the OSB proxy: same WSDL, same port, same path; PAYLOAD mode so $body == SOAP Body content ---
        from("cxf:/{{osb.proxy.ContributorEnquiryPS.path}}?wsdlURL=classpath:osb/{{project}}/WSDL/ContributorEnquiry.wsdl"
             + "&serviceName={http://example.com/integration/contributor/v1}ContributorEnquiryService"
             + "&portName={http://example.com/integration/contributor/v1}ContributorEnquiryPort&dataFormat=PAYLOAD")
            .routeId("{{ProxyName}}")
            .description("OSB proxy {{proxy_ref}} ({{proxy_uris}})")
            .process(OsbBodyWrapper.wrap()).id("osb-wrap")                       // <Body>payload</Body>: OSB $body semantics
            .setProperty("osb.operation", header(CxfConstants.OPERATION_NAME))
            .choice().id("OperationBranch")                                        // OSB operational branch
                .when(exchangeProperty("osb.operation").isEqualTo("getContributor")).to("direct:{{ProxyName}}-getContributor")
                .when(exchangeProperty("osb.operation").isEqualTo("updateContributor")).to("direct:{{ProxyName}}-updateContributor")
                .otherwise().throwException(new OsbFaultException("OSB-380002", "Unknown operation"))
            .end()
            .process(OsbBodyWrapper.unwrap()).id("osb-reply");                    // the reply is the bare payload

        // --- operation getContributor = pipeline pair GetContributorRequest / GetContributorResponse + route node ----
        from("direct:{{ProxyName}}-getContributor")
            .routeId("{{ProxyName}}-getContributor")
            .description("OSB pipeline GetContributorRequest -> RouteToCore -> GetContributorResponse")
            // stage ValidateAndEnrich
            .process(OsbBodyWrapper.unwrap()).to("validator:classpath:osb/{{project}}/XSD/Contributor.xsd").id("_ActionId-1").process(OsbBodyWrapper.rewrap())
            .setProperty(P_CONTRIBUTOR_ID, OsbXQuery.of("$body/ns:getContributorRequest/ns:contributorId/text()").ns(NS).asString()).id("_ActionId-2")
            .setProperty(P_MEMBER_REQ, OsbXQuery.of(
                "<mem:lookupMemberRequest><mem:nationalId>{ $body/ns:getContributorRequest/ns:nationalId/text() }</mem:nationalId></mem:lookupMemberRequest>")
                .ns(NS).asNode()).id("_ActionId-3")
            // _ActionId-4 service callout: send the request variable (bare), keep $body, capture the response variable
            .setProperty("osb.savedBody", body())
            .setBody(exchangeProperty(P_MEMBER_REQ))
            .setHeader(CxfConstants.OPERATION_NAME, constant("lookupMember"))
            .setProperty("osb.backend", constant("MemberLookupBS"))
            .to(EP_MEMBER).id("_ActionId-4")
            .setProperty(P_MEMBER_RESP, body())
            .setBody(exchangeProperty("osb.savedBody"))
            // _ActionId-5 ifThenElse on the callout result (OSB condition copied verbatim)
            .choice().id("_ActionId-5")
                .when(OsbXQuery.of("$memberResp/mem:lookupMemberResponse/mem:status/text() = 'ACTIVE'").ns(NS).asPredicate())
                    // _ActionId-6 replace $body contents-only with the stored XQuery, parameters bound by their OSB names
                    .process(OsbXQuery.resource("osb/{{project}}/Transform/MemberToContributor.xqy").ns(NS)
                                      .param("member", P_MEMBER_RESP, "$memberResp/mem:lookupMemberResponse")
                                      .param("contributorId", P_CONTRIBUTOR_ID)
                                      .replaceBodyContentsOnly()).id("_ActionId-6")
                    // _ActionId-7 transportHeaders copy-all=false: strip inbound headers, set the one the pipeline set
                    .removeHeaders("*", CxfConstants.OPERATION_NAME, "SOAPAction", "Content-Type")
                    .setHeader("X-Correlation-Id", OsbXQuery.of("$inbound/ctx:transport/ctx:request/tp:headers/http:X-Correlation-Id/text()").ns(NS).asString()).id("_ActionId-7")
                .otherwise()
                    .throwException(new OsbFaultException("AMN-4001", "Member is not active")).id("_ActionId-8")
            .end()
            // route node RouteToCore (_ActionId-15): terminal request-response call; the response pipeline follows
            .process(OsbBodyWrapper.unwrap())                                      // backend gets the bare payload
            .setHeader(CxfConstants.OPERATION_NAME, constant("getContributor"))
            .setProperty("osb.backend", constant("ContributorCoreBS"))
            .to(EP_CORE).id("_ActionId-15")
            .process(OsbBodyWrapper.rewrap())                                      // backend response is the new $body
            // response stage AuditAndLog
            .log(LoggingLevel.INFO, "{{logger}}", "getContributor done for ${exchangeProperty.contributorId}").id("_ActionId-9")
            .wireTap("direct:{{ProxyName}}-publishAudit").id("_ActionId-10")
            .end();

        // publish = one-way copy with its own outbound transform (_ActionId-11), InOnly on the broker
        from("direct:{{ProxyName}}-publishAudit")
            .routeId("{{ProxyName}}-publishAudit")
            .description("OSB publish to AuditQueueBS, response-required=false")
            .setBody(OsbXQuery.of("<audit><op>getContributor</op><id>{ $contributorId }</id></audit>").ns(NS).asNode()).id("_ActionId-11")
            .setExchangePattern(ExchangePattern.InOnly)
            .to(EP_AUDIT).id("publish-audit");

        // --- operation updateContributor: pass-through pipeline + route node ---------------------------------------
        from("direct:{{ProxyName}}-updateContributor")
            .routeId("{{ProxyName}}-updateContributor")
            .description("OSB pipeline UpdateContributorRequest -> RouteUpdateToCore")
            .log(LoggingLevel.DEBUG, "{{logger}}", "updateContributor").id("_ActionId-12")
            .process(OsbBodyWrapper.unwrap())
            .setHeader(CxfConstants.OPERATION_NAME, constant("updateContributor"))
            .setProperty("osb.backend", constant("ContributorCoreBS"))
            .to(EP_CORE).id("_ActionId-16")
            .process(OsbBodyWrapper.rewrap());
    }
}
