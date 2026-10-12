package {{package}}.osb;

import net.sf.saxon.s9api.Processor;
import net.sf.saxon.s9api.QName;
import net.sf.saxon.s9api.SaxonApiException;
import net.sf.saxon.s9api.XQueryCompiler;
import net.sf.saxon.s9api.XQueryEvaluator;
import net.sf.saxon.s9api.XQueryExecutable;
import net.sf.saxon.s9api.XdmAtomicValue;
import net.sf.saxon.s9api.XdmItem;
import net.sf.saxon.s9api.XdmNode;
import net.sf.saxon.s9api.XdmValue;
import org.apache.camel.Exchange;
import org.apache.camel.Expression;
import org.apache.camel.Predicate;
import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.Node;

import javax.xml.parsers.DocumentBuilderFactory;
import javax.xml.transform.dom.DOMSource;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * TEMPLATE: the support classes every migrated OSB module shares. Split into one file per class in the module.
 *
 * Why they exist: OSB expressions assume a context that Camel does not provide out of the box.
 *  - OSB's $body is the SOAP Body CONTENT; Camel's body is whatever the component delivered.
 *  - OSB expressions name pipeline variables directly ($memberResp); Camel's xquery language binds the message as the
 *    context item and headers as $in.headers.<name>, so "$body/ns:x" is an undeclared variable there.
 *  - OSB's $fault is an element with errorCode/reason/details/location; Camel has an exception on the exchange.
 *
 * The rule the templates follow: run every OSB expression, inline or stored, through {@link OsbXQuery} (Saxon s9api),
 * which binds $body to the <Body>-wrapped document, every exchange property by its OSB variable name, and $inbound /
 * $fault to small context elements. Zero edits to OSB expressions. Camel's own xquery()/xpath() languages are fine for
 * expressions you write yourself, never for copied OSB ones.
 */
public final class OsbSupport {
    private OsbSupport() {}

    static final String CTX = "http://www.bea.com/wli/sb/context";
    static final String TP = "http://www.bea.com/wli/sb/transports";
    static final String HTTP = "http://www.bea.com/wli/sb/transports/http";

    static Document newDocument() throws Exception {
        DocumentBuilderFactory f = DocumentBuilderFactory.newInstance();
        f.setNamespaceAware(true);
        f.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
        return f.newDocumentBuilder().newDocument();
    }

    // ------------------------------------------------------------------------------------------------ body wrapper
    /**
     * OSB $body semantics. wrap() runs once at the inbound: it captures the transport headers as properties
     * (osb.inbound.*) and wraps the payload in <Body>. unwrap() runs BEFORE EVERY OUTBOUND CALL (route node, service
     * callout, publish) so the backend receives the bare payload, and rewrap() runs after a request-response call so
     * the response pipeline sees the backend response under $body again. The final unwrap() is the reply.
     */
    public static final class OsbBodyWrapper {
        public static final String WRAPPER = "Body";

        public static org.apache.camel.Processor wrap() {
            return exchange -> {
                exchange.getMessage().getHeaders().forEach((k, v) -> exchange.setProperty("osb.inbound." + k, v));
                rewrap().process(exchange);
            };
        }

        public static org.apache.camel.Processor rewrap() {
            return exchange -> {
                Document payload = exchange.getMessage().getBody(Document.class);  // Camel converts CxfPayload/String/Source
                Document doc = newDocument();
                Element body = doc.createElement(WRAPPER);
                doc.appendChild(body);
                if (payload != null && payload.getDocumentElement() != null) {
                    body.appendChild(doc.importNode(payload.getDocumentElement(), true));
                }
                exchange.getMessage().setBody(doc);
            };
        }

        public static org.apache.camel.Processor unwrap() {
            return exchange -> {
                Document doc = exchange.getMessage().getBody(Document.class);
                if (doc == null || doc.getDocumentElement() == null) return;
                Element root = doc.getDocumentElement();
                if (!WRAPPER.equals(root.getLocalName())) return;
                Node first = root.getFirstChild();
                while (first != null && first.getNodeType() != Node.ELEMENT_NODE) first = first.getNextSibling();
                if (first == null) { exchange.getMessage().setBody(null); return; }
                Document out = newDocument();
                out.appendChild(out.importNode(first, true));
                exchange.getMessage().setBody(out);
            };
        }
    }

    // ------------------------------------------------------------------------------------------------ OSB XQuery
    /**
     * Compiles an OSB XQuery expression once and evaluates it against the exchange with OSB's variable semantics.
     * Usage in a RouteBuilder:
     *   .setProperty("contributorId", OsbXQuery.of("$body/ns:getContributorRequest/ns:contributorId/text()").ns(NS).asString())
     *   .when(OsbXQuery.of("$memberResp/mem:lookupMemberResponse/mem:status/text() = 'ACTIVE'").ns(NS).asPredicate())
     *   .setBody(OsbXQuery.of("<audit><id>{ $contributorId }</id></audit>").ns(NS).asNode())
     *   .process(OsbXQuery.resource("osb/P/Transform/MemberToContributor.xqy").ns(NS).param("member", "memberResp", "/mem:lookupMemberResponse").param("contributorId", "contributorId").replaceBodyContentsOnly())
     * Every $name in the expression that is not body/header/inbound/outbound/fault/operation is bound from the exchange
     * property of that name (a DOM Node for element values, an atomic for strings/numbers). Stored queries that declare
     * "declare variable $x external;" are bound the same way, by name.
     */
    public static final class OsbXQuery {
        private static final Processor SAXON = new Processor(false);
        private static final Set<String> BUILTIN = Set.of("body", "header", "inbound", "outbound", "fault", "operation", "attachments", "messageID");
        private static final Pattern VAR = Pattern.compile("\\$([A-Za-z_][A-Za-z0-9_.-]*)");

        private final String source;
        private final boolean stored;                 // stored .xqy: declares its own externals; inline: we declare them
        private final Map<String, String> namespaces = new LinkedHashMap<>();
        private final Map<String, String[]> params = new LinkedHashMap<>();   // param -> {propertyName, xpathWithinProperty}
        private XQueryExecutable compiled;

        private OsbXQuery(String source, boolean stored) { this.source = source; this.stored = stored; }
        public static OsbXQuery of(String inlineExpression) { return new OsbXQuery(inlineExpression, false); }
        public static OsbXQuery resource(String classpath) {
            try (InputStream in = OsbSupport.class.getClassLoader().getResourceAsStream(classpath)) {
                if (in == null) throw new IllegalArgumentException("XQuery resource not found: " + classpath);
                return new OsbXQuery(new String(in.readAllBytes(), StandardCharsets.UTF_8), true);
            } catch (java.io.IOException e) { throw new IllegalStateException(e); }
        }
        public OsbXQuery ns(Map<String, String> prefixToUri) { namespaces.putAll(prefixToUri); return this; }
        public OsbXQuery param(String name, String property) { params.put(name, new String[]{property, null}); return this; }
        public OsbXQuery param(String name, String property, String xpath) { params.put(name, new String[]{property, xpath}); return this; }

        private synchronized XQueryExecutable compile() throws SaxonApiException {
            if (compiled != null) return compiled;
            XQueryCompiler c = SAXON.newXQueryCompiler();
            namespaces.forEach(c::declareNamespace);
            String text = source;
            if (!stored) {
                StringBuilder prolog = new StringBuilder();
                for (String v : referencedVariables()) prolog.append("declare variable $").append(v).append(" external;\n");
                text = prolog + source;
            }
            compiled = c.compile(text);
            return compiled;
        }

        private Set<String> referencedVariables() {
            Set<String> out = new java.util.LinkedHashSet<>();
            Matcher m = VAR.matcher(source);
            while (m.find()) out.add(m.group(1));
            return out;
        }

        public XdmValue evaluate(Exchange exchange) throws Exception {
            XQueryEvaluator ev = compile().load();
            for (String v : stored ? params.keySet() : referencedVariables()) {
                Object value;
                if (stored) {
                    String[] p = params.get(v);
                    value = exchange.getProperty(p[0]);
                    if (value instanceof Node n && p[1] != null) value = selectWithin(n, p[1]);
                } else if ("body".equals(v)) {
                    value = exchange.getMessage().getBody(Document.class);
                } else if ("inbound".equals(v)) {
                    value = inboundContext(exchange);
                } else if ("fault".equals(v)) {
                    value = exchange.getProperty("osb.fault.element");
                } else if ("operation".equals(v)) {
                    value = exchange.getProperty("osb.operation");
                } else if (BUILTIN.contains(v)) {
                    value = null;
                } else {
                    value = exchange.getProperty(v);
                }
                ev.setExternalVariable(new QName(v), toXdm(value));
            }
            return ev.evaluate();
        }

        /** The OSB $body/... path inside a stored-query parameter (<con1:path>$memberResp/mem:lookupMemberResponse</con1:path>). */
        private Object selectWithin(Node n, String xpath) throws Exception {
            OsbXQuery sub = OsbXQuery.of(xpath.replaceFirst("^\\$[A-Za-z_][\\w.-]*", "\\$v")).ns(namespaces);
            XQueryEvaluator ev = sub.compile().load();
            ev.setExternalVariable(new QName("v"), toXdm(n));
            XdmValue r = ev.evaluate();
            return r.size() == 0 ? null : r;
        }

        private static XdmValue toXdm(Object value) throws SaxonApiException {
            if (value == null) return XdmValue.makeSequence(java.util.List.of());
            if (value instanceof XdmValue x) return x;
            if (value instanceof Node n) {
                XdmNode node = SAXON.newDocumentBuilder().build(new DOMSource(n));
                // bind the element, not the document node, so $var/child::x works as it did in OSB
                return n.getNodeType() == Node.DOCUMENT_NODE && node.axisIterator(net.sf.saxon.s9api.Axis.CHILD).hasNext()
                    ? node.axisIterator(net.sf.saxon.s9api.Axis.CHILD).next() : node;
            }
            if (value instanceof String s) return new XdmAtomicValue(s);
            if (value instanceof Integer i) return new XdmAtomicValue(i);
            if (value instanceof Long l) return new XdmAtomicValue(l);
            if (value instanceof Boolean b) return new XdmAtomicValue(b);
            if (value instanceof java.math.BigDecimal d) return new XdmAtomicValue(d);
            return new XdmAtomicValue(String.valueOf(value));
        }

        /** $inbound/ctx:transport/ctx:request/tp:headers/http:<Name> built from the captured inbound headers. */
        private static Document inboundContext(Exchange exchange) throws Exception {
            Document d = newDocument();
            Element inbound = d.createElementNS(CTX, "ctx:inbound"); d.appendChild(inbound);
            Element transport = d.createElementNS(CTX, "ctx:transport"); inbound.appendChild(transport);
            Element request = d.createElementNS(CTX, "ctx:request"); transport.appendChild(request);
            Element headers = d.createElementNS(TP, "tp:headers"); request.appendChild(headers);
            for (Map.Entry<String, Object> e : exchange.getProperties().entrySet()) {
                if (e.getKey().startsWith("osb.inbound.") && e.getValue() != null) {
                    String name = e.getKey().substring("osb.inbound.".length());
                    if (!name.matches("[A-Za-z_][A-Za-z0-9_.-]*")) continue;
                    Element h = d.createElementNS(HTTP, "http:" + name);
                    h.setTextContent(String.valueOf(e.getValue()));
                    headers.appendChild(h);
                }
            }
            Element service = d.createElementNS(CTX, "ctx:service"); inbound.appendChild(service);
            Element op = d.createElementNS(CTX, "ctx:operation"); op.setTextContent(String.valueOf(exchange.getProperty("osb.operation", ""))); service.appendChild(op);
            return d;
        }

        // ---- adapters for the Camel DSL
        public Expression asString() {
            return new Expression() {
                @Override public <T> T evaluate(Exchange exchange, Class<T> type) {
                    try { XdmValue v = OsbXQuery.this.evaluate(exchange); return type.cast(v.size() == 0 ? null : v.itemAt(0).getStringValue()); }
                    catch (Exception e) { throw new RuntimeException(e); }
                }
            };
        }
        public Expression asNode() {
            return new Expression() {
                @Override public <T> T evaluate(Exchange exchange, Class<T> type) {
                    try {
                        XdmValue v = OsbXQuery.this.evaluate(exchange);
                        if (v.size() == 0) return null;
                        XdmItem item = v.itemAt(0);
                        Node n = net.sf.saxon.dom.NodeOverNodeInfo.wrap(((XdmNode) item).getUnderlyingNode());
                        Document d = newDocument(); d.appendChild(d.importNode(n, true));
                        return type.cast(d);
                    } catch (Exception e) { throw new RuntimeException(e); }
                }
            };
        }
        public Predicate asPredicate() {
            return exchange -> {
                try { XdmValue v = OsbXQuery.this.evaluate(exchange); return v.size() > 0 && ((XdmAtomicValue) v.itemAt(0)).getBooleanValue(); }
                catch (Exception e) { throw new RuntimeException(e); }
            };
        }
        /** OSB "Replace ... contents-only=true" on $body: keep the <Body> wrapper, replace its children with the result. */
        public org.apache.camel.Processor replaceBodyContentsOnly() {
            return exchange -> {
                Document result = asNode().evaluate(exchange, Document.class);
                Document body = exchange.getMessage().getBody(Document.class);
                Element wrapper = body.getDocumentElement();
                while (wrapper.getFirstChild() != null) wrapper.removeChild(wrapper.getFirstChild());
                if (result != null) wrapper.appendChild(body.importNode(result.getDocumentElement(), true));
            };
        }
        /** OSB "Replace ... contents-only=false" on $body: the result becomes the whole payload (re-wrapped). */
        public org.apache.camel.Processor replaceBody() {
            return exchange -> {
                Document result = asNode().evaluate(exchange, Document.class);
                exchange.getMessage().setBody(result);
                OsbBodyWrapper.rewrap().process(exchange);
            };
        }
    }

    // ------------------------------------------------------------------------------------------------ faults
    /** Raised by OSB "Raise Error" actions and by the processors; carries the contractual error code. */
    public static class OsbFaultException extends RuntimeException {
        private final String errorCode;
        public OsbFaultException(String errorCode, String reason) { super(reason); this.errorCode = errorCode; }
        public String getErrorCode() { return errorCode; }
    }

    /**
     * Builds the $fault equivalents: headers osb.fault.* and a <ctx:fault> element (property osb.fault.element and the
     * message body), so the original fault XSLT runs on the input it had in OSB. Codes follow OSB 12c ranges; user codes
     * pass through unchanged.
     */
    public static final class OsbFaultProcessor implements org.apache.camel.Processor {
        @Override
        public void process(Exchange exchange) throws Exception {
            Throwable t = exchange.getProperty(Exchange.EXCEPTION_CAUGHT, Throwable.class);
            String code = (t instanceof OsbFaultException f) ? f.getErrorCode() : codeFor(t);
            String reason = t == null ? "unknown" : String.valueOf(t.getMessage());
            exchange.getMessage().setHeader("osb.fault.errorCode", code);
            exchange.getMessage().setHeader("osb.fault.reason", reason);
            exchange.getMessage().setHeader("osb.fault.location.node", exchange.getProperty(Exchange.FAILURE_ROUTE_ID));
            exchange.getMessage().setHeader("osb.fault.java-exception", t == null ? "" : t.getClass().getName());
            Document doc = newDocument();
            Element fault = doc.createElementNS(CTX, "ctx:fault"); doc.appendChild(fault);
            Element ec = doc.createElementNS(CTX, "ctx:errorCode"); ec.setTextContent(code); fault.appendChild(ec);
            Element rs = doc.createElementNS(CTX, "ctx:reason"); rs.setTextContent(reason); fault.appendChild(rs);
            Element loc = doc.createElementNS(CTX, "ctx:location"); fault.appendChild(loc);
            Element node = doc.createElementNS(CTX, "ctx:node"); node.setTextContent(String.valueOf(exchange.getProperty(Exchange.FAILURE_ROUTE_ID, ""))); loc.appendChild(node);
            exchange.setProperty("osb.fault.element", doc);
            exchange.getMessage().setBody(doc);
        }

        /** Exception type -> nearest OSB range: transport 380000s, pipeline runtime 382000s, actions 382500s. */
        static String codeFor(Throwable t) {
            if (t == null) return "OSB-382000";
            String n = t.getClass().getName();
            if (n.contains("Connect") || n.contains("Timeout") || n.contains("Http")) return "OSB-380001";
            if (n.contains("Validation") || n.contains("SAXParse")) return "OSB-382505";
            return "OSB-382000";
        }

        /** OSB "Reply with failure": the body produced by the fault XSLT is returned as a SOAP fault. */
        public static void replyWithSoapFault(Exchange exchange) {
            // camel-cxf PAYLOAD mode: a SoapFault set as the exception (or a <soapenv:Fault> body with HTTP 500) is
            // returned as a fault envelope. Project-specific; see references/osb-action-mapping.md, "reply isErrorReply".
            exchange.getMessage().setHeader(Exchange.HTTP_RESPONSE_CODE, 500);
        }
    }
}
