//DEPS org.apache.camel:camel-jackson
package osb.common;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.apache.camel.Exchange;
import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.Node;

import javax.xml.parsers.DocumentBuilderFactory;
import javax.xml.transform.OutputKeys;
import javax.xml.transform.TransformerFactory;
import javax.xml.transform.dom.DOMSource;
import javax.xml.transform.stream.StreamResult;
import java.io.File;
import java.io.StringWriter;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * OSB nXSD translation Native-To-XML for JSON payloads (nxsd:version="JSON"), the same for every flow.
 *
 * OSB step:   nxsdTranslation type=Native-To-XML, nxsd=<schema>, schemaElement=<root>   then   replace $body
 * Camel step: setProperty osbNxsd=<path of the .xsd>, osbNxsdRoot=<root element name>, then bean OsbNxsd.toXml
 *
 * The XML follows the schema, not the JSON: elements in schema order, in the schema's target namespace when
 * elementFormDefault="qualified", a JSON array becomes the repeated element (maxOccurs > 1), an array of arrays the
 * nxsd nestedArray/nestedArrayItem wrappers, null and absent fields no element. JSON fields the schema does not
 * know are not written (counted in the exchange property osbNxsdUnknown, for the logs).
 */
public final class OsbNxsd {
    private static final String XS = "http://www.w3.org/2001/XMLSchema";
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final Map<String, Schema> CACHE = new ConcurrentHashMap<>();

    private OsbNxsd() {}

    /** Route step: JSON body -> XML body per the schema in the exchange property osbNxsd (root: osbNxsdRoot). */
    public static void toXml(Exchange exchange) throws Exception {
        String xsd = exchange.getProperty("osbNxsd", String.class);
        String root = exchange.getProperty("osbNxsdRoot", String.class);
        int[] unknown = {0};
        String xml = toXml(exchange.getMessage().getBody(String.class), xsd, root, unknown);
        exchange.setProperty("osbNxsdUnknown", unknown[0]);
        exchange.getMessage().setBody(xml);
    }

    public static String toXml(String json, String xsdPath, String rootName, int[] unknown) throws Exception {
        Schema s = CACHE.computeIfAbsent(xsdPath, Schema::load);
        Decl root = s.root(rootName);
        JsonNode in = JSON.readTree(json);
        Document doc = newDocument();
        Element top = doc.createElementNS(root.ns, root.name);
        doc.appendChild(top);
        fill(doc, top, root, in, unknown);
        return serialize(doc);
    }

    private static void fill(Document doc, Element el, Decl decl, JsonNode value, int[] unknown) {
        if (value == null || value.isNull()) {
            return;
        }
        if (decl.children.isEmpty()) {
            el.setTextContent(value.isValueNode() ? value.asText() : value.toString());
            return;
        }
        if (value.isObject()) {
            value.fieldNames().forEachRemaining(f -> {
                if (decl.children.stream().noneMatch(c -> c.name.equals(f))) {
                    unknown[0]++;
                }
            });
            for (Decl c : decl.children) {
                add(doc, el, c, value.get(c.name), unknown);
            }
        } else if (value.isArray() && decl.children.size() == 1) {      // nested array: <nestedArray><nestedArrayItem/>...
            Decl c = decl.children.get(0);                               // one element per inner array / per item
            for (JsonNode item : value) {
                if (item == null || item.isNull()) {
                    continue;
                }
                Element e = doc.createElementNS(c.ns, c.name);
                el.appendChild(e);
                fill(doc, e, c, item, unknown);
            }
        }
    }

    private static void add(Document doc, Element parent, Decl c, JsonNode v, int[] unknown) {
        if (v == null || v.isNull()) {
            return;
        }
        List<JsonNode> items = new ArrayList<>();
        if (v.isArray() && c.repeats) {
            v.forEach(items::add);
        } else {
            items.add(v);
        }
        for (JsonNode item : items) {
            Element e = parent.getOwnerDocument().createElementNS(c.ns, c.name);
            parent.appendChild(e);
            fill(doc, e, c, item, unknown);
        }
    }

    static Document newDocument() throws Exception {
        DocumentBuilderFactory f = DocumentBuilderFactory.newInstance();
        f.setNamespaceAware(true);
        f.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
        return f.newDocumentBuilder().newDocument();
    }

    static String serialize(Document doc) throws Exception {
        var t = TransformerFactory.newInstance().newTransformer();
        t.setOutputProperty(OutputKeys.OMIT_XML_DECLARATION, "yes");
        StringWriter w = new StringWriter();
        t.transform(new DOMSource(doc), new StreamResult(w));
        return w.toString();
    }

    /** One element of the schema: name, namespace, repeats (maxOccurs > 1), child elements in schema order. */
    static final class Decl {
        final String name;
        final String ns;
        final boolean repeats;
        final List<Decl> children = new ArrayList<>();

        Decl(String name, String ns, boolean repeats) {
            this.name = name;
            this.ns = ns;
            this.repeats = repeats;
        }
    }

    static final class Schema {
        final Element schema;
        final String tns;
        final boolean qualified;
        final Map<String, Element> types = new ConcurrentHashMap<>();
        final Map<String, Element> elements = new ConcurrentHashMap<>();

        private Schema(Element schema) {
            this.schema = schema;
            this.tns = schema.getAttribute("targetNamespace").isEmpty() ? null : schema.getAttribute("targetNamespace");
            this.qualified = "qualified".equals(schema.getAttribute("elementFormDefault"));
            for (Node n = schema.getFirstChild(); n != null; n = n.getNextSibling()) {
                if (n instanceof Element e && XS.equals(e.getNamespaceURI())) {
                    if ("complexType".equals(e.getLocalName())) {
                        types.put(e.getAttribute("name"), e);
                    } else if ("element".equals(e.getLocalName())) {
                        elements.put(e.getAttribute("name"), e);
                    }
                }
            }
        }

        static Schema load(String path) {
            try {
                DocumentBuilderFactory f = DocumentBuilderFactory.newInstance();
                f.setNamespaceAware(true);
                f.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
                return new Schema(f.newDocumentBuilder().parse(new File(path)).getDocumentElement());
            } catch (Exception e) {
                throw new IllegalArgumentException("cannot read nXSD schema " + path + ": " + e.getMessage(), e);
            }
        }

        Decl root(String name) {
            String local = name == null || name.isBlank() ? null : name.substring(name.indexOf(':') + 1);
            Element e = local != null ? elements.get(local) : elements.values().stream().findFirst().orElse(null);
            if (e == null) {
                throw new IllegalArgumentException("root element " + name + " not in the nXSD schema");
            }
            return decl(e, true, 0);
        }

        private Decl decl(Element e, boolean global, int depth) {
            if (!e.getAttribute("ref").isEmpty()) {
                return decl(elements.get(local(e.getAttribute("ref"))), true, depth);
            }
            String max = e.getAttribute("maxOccurs");
            boolean repeats = "unbounded".equals(max) || (!max.isEmpty() && Integer.parseInt(max) > 1);
            Decl d = new Decl(e.getAttribute("name"), global || qualified ? tns : null, repeats);
            if (depth > 40) {
                return d;
            }
            Element ct = child(e, "complexType");
            if (ct == null && !e.getAttribute("type").isEmpty()) {
                ct = types.get(local(e.getAttribute("type")));
            }
            if (ct != null) {
                collect(ct, d, depth);
            }
            return d;
        }

        private void collect(Element container, Decl d, int depth) {
            for (Node n = container.getFirstChild(); n != null; n = n.getNextSibling()) {
                if (!(n instanceof Element e) || !XS.equals(e.getNamespaceURI())) {
                    continue;
                }
                switch (e.getLocalName()) {
                    case "element" -> d.children.add(decl(e, false, depth + 1));
                    case "sequence", "all", "choice", "complexContent", "extension" -> collect(e, d, depth);
                    default -> { }
                }
            }
        }

        private static Element child(Element e, String local) {
            for (Node n = e.getFirstChild(); n != null; n = n.getNextSibling()) {
                if (n instanceof Element c && XS.equals(c.getNamespaceURI()) && local.equals(c.getLocalName())) {
                    return c;
                }
            }
            return null;
        }

        private static String local(String qname) {
            return qname.substring(qname.indexOf(':') + 1);
        }
    }
}
