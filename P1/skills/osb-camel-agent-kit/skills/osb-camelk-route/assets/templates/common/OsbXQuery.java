//DEPS net.sf.saxon:Saxon-HE:12.9
package osb.common;

import net.sf.saxon.s9api.DocumentBuilder;
import net.sf.saxon.s9api.ExtensionFunction;
import net.sf.saxon.s9api.ItemType;
import net.sf.saxon.s9api.OccurrenceIndicator;
import net.sf.saxon.s9api.Processor;
import net.sf.saxon.s9api.QName;
import net.sf.saxon.s9api.SequenceType;
import net.sf.saxon.s9api.Serializer;
import net.sf.saxon.s9api.XQueryCompiler;
import net.sf.saxon.s9api.XQueryEvaluator;
import net.sf.saxon.s9api.XQueryExecutable;
import net.sf.saxon.s9api.XdmAtomicValue;
import net.sf.saxon.s9api.XdmNode;
import net.sf.saxon.s9api.XdmNodeKind;
import net.sf.saxon.s9api.XdmValue;
import org.apache.camel.Exchange;

import javax.xml.transform.stream.StreamSource;
import java.io.File;
import java.io.StringReader;
import java.io.StringWriter;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Runs an OSB XQuery file (.xqy from the export, unchanged) the way the OSB pipeline ran it, the same for every flow.
 *
 * OSB step:   assign var = xqueryTransform(resource=<xqy>, param <name> = $body/*)   then   replace $body with $var
 * Camel step: setProperty osbXQuery=<path of the .xqy>, osbXQueryParam=<param name, default input>,
 *             then bean OsbXQuery.transform   (the body becomes the XQuery result, serialized without declaration)
 *
 * The body (XML) is bound to the external variable named osbXQueryParam as its root element, like OSB's $body/*.
 * Every exchange property osbVar.<name> is bound to the external variable $<name> (string), e.g. a pipeline variable.
 * OSB extension functions that the XQuery calls: fn-bea:uuid() here; any other fn-bea function fails the
 * compilation with its name in the message, so a flow that needs one is visible at the first test run.
 */
public final class OsbXQuery {
    private static final String FN_BEA = "http://www.bea.com/xquery/xquery-functions";
    private static final Processor SAXON = new Processor(false);
    private static final Map<String, XQueryExecutable> CACHE = new ConcurrentHashMap<>();

    static {
        SAXON.registerExtensionFunction(new ExtensionFunction() {   // fn-bea:serialize($node): the node as a string, as OSB logs it
            public QName getName() {
                return new QName(FN_BEA, "serialize");
            }

            public SequenceType getResultType() {
                return SequenceType.makeSequenceType(ItemType.STRING, OccurrenceIndicator.ONE);
            }

            public SequenceType[] getArgumentTypes() {
                return new SequenceType[] {SequenceType.makeSequenceType(ItemType.ANY_ITEM, OccurrenceIndicator.ZERO_OR_MORE)};
            }

            public XdmValue call(XdmValue[] args) {
                try {
                    StringWriter w = new StringWriter();
                    Serializer ser = SAXON.newSerializer(w);
                    ser.setOutputProperty(Serializer.Property.OMIT_XML_DECLARATION, "yes");
                    ser.serializeXdmValue(args[0]);
                    return new XdmAtomicValue(w.toString());
                } catch (Exception e) {
                    throw new IllegalStateException("fn-bea:serialize: " + e.getMessage(), e);
                }
            }
        });
        SAXON.registerExtensionFunction(new ExtensionFunction() {
            public QName getName() {
                return new QName(FN_BEA, "uuid");
            }

            public SequenceType getResultType() {
                return SequenceType.makeSequenceType(ItemType.STRING, OccurrenceIndicator.ONE);
            }

            public SequenceType[] getArgumentTypes() {
                return new SequenceType[0];
            }

            public XdmValue call(XdmValue[] args) {
                return new XdmAtomicValue(UUID.randomUUID().toString());
            }
        });
    }

    private OsbXQuery() {}

    /** Route step: body = result of the XQuery in osbXQuery applied to the body (bound to $osbXQueryParam). */
    public static void transform(Exchange exchange) throws Exception {
        String path = OsbNxsd.file(exchange, exchange.getProperty("osbXQuery", String.class));
        String param = exchange.getProperty("osbXQueryParam", "input", String.class);
        XQueryEvaluator q = CACHE.computeIfAbsent(path, OsbXQuery::compile).load();
        DocumentBuilder b = SAXON.newDocumentBuilder();
        XdmNode doc = b.build(new StreamSource(new StringReader(exchange.getMessage().getBody(String.class))));
        XdmNode root = doc.children().iterator().next();
        for (XdmNode n : doc.children()) {
            if (n.getNodeKind() == XdmNodeKind.ELEMENT) {
                root = n;
                break;
            }
        }
        q.setExternalVariable(new QName(param), root);
        exchange.getProperties().forEach((k, v) -> {
            if (k.startsWith("osbVar.") && v != null) {
                q.setExternalVariable(new QName(k.substring(7)), new XdmAtomicValue(v.toString()));
            }
        });
        StringWriter w = new StringWriter();
        Serializer s = SAXON.newSerializer(w);
        s.setOutputProperty(Serializer.Property.OMIT_XML_DECLARATION, "yes");
        s.setOutputProperty(Serializer.Property.INDENT, "no");
        q.run(s);
        exchange.getMessage().setBody(w.toString());
    }

    private static XQueryExecutable compile(String path) {
        try {
            XQueryCompiler c = SAXON.newXQueryCompiler();
            c.declareNamespace("fn-bea", FN_BEA);
            return c.compile(new File(path));
        } catch (Exception e) {
            throw new IllegalArgumentException("cannot compile OSB XQuery " + path + ": " + e.getMessage(), e);
        }
    }
}
