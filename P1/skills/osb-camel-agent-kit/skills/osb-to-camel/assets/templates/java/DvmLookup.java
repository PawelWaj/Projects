package {{package}}.support;

import net.sf.saxon.s9api.ExtensionFunction;
import net.sf.saxon.s9api.ItemType;
import net.sf.saxon.s9api.OccurrenceIndicator;
import net.sf.saxon.s9api.QName;
import net.sf.saxon.s9api.SequenceType;
import net.sf.saxon.s9api.XdmAtomicValue;
import net.sf.saxon.s9api.XdmValue;
import org.w3c.dom.Element;
import org.w3c.dom.NodeList;

import javax.xml.parsers.DocumentBuilderFactory;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * TEMPLATE (main code, not a test): DVM (domain value map) lookups the OSB pipeline did with its .dvm resources.
 * The .dvm files are exported from OSB unchanged (DG1) and live in src/main/resources/dvm/. The same class serves the
 * route (.bean(DvmLookup.class, "lookup(...)")) and the golden tests (registered in Saxon as an extension function),
 * so the original XQuery runs unchanged.
 *
 * File shape (Oracle DVM): <dvm name="..."><columns><column name="A"/>...</columns><rows><row><cell>..</cell>...</row></rows></dvm>
 * The namespace of the dvm XML and of the XQuery lookup function are taken from the export; do not assume them
 * (FUNCTION_NS below is filled from the original .xqy's namespace declaration).
 *
 * Test data: the exported .dvm IS the mock; tests assert both a mapped value and the default for an unmapped one.
 */
public final class DvmLookup {

    public static final String FUNCTION_NS = "{{dvm_function_namespace_from_xqy}}";

    private static final Map<String, List<Map<String, String>>> CACHE = new ConcurrentHashMap<>();

    private DvmLookup() {
    }

    /** OSB semantics: first row whose source column equals the value; the default when none matches. */
    public static String lookup(String dvm, String sourceColumn, String sourceValue, String targetColumn, String defaultValue) {
        for (Map<String, String> row : rows(dvm)) {
            if (sourceValue != null && sourceValue.equals(row.get(sourceColumn))) {
                String v = row.get(targetColumn);
                return v != null ? v : defaultValue;
            }
        }
        return defaultValue;
    }

    static List<Map<String, String>> rows(String dvm) {
        return CACHE.computeIfAbsent(dvm, DvmLookup::load);
    }

    private static List<Map<String, String>> load(String dvm) {
        String path = "dvm/" + (dvm.endsWith(".dvm") ? dvm : dvm + ".dvm");
        try (InputStream in = DvmLookup.class.getClassLoader().getResourceAsStream(path)) {
            if (in == null) {
                throw new IllegalStateException("DVM not on the classpath: " + path + " (export it from OSB, DG1)");
            }
            DocumentBuilderFactory f = DocumentBuilderFactory.newInstance();
            f.setNamespaceAware(true);
            f.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
            var doc = f.newDocumentBuilder().parse(in);
            NodeList cols = doc.getElementsByTagNameNS("*", "column");
            List<String> names = new ArrayList<>();
            for (int i = 0; i < cols.getLength(); i++) {
                names.add(((Element) cols.item(i)).getAttribute("name"));
            }
            List<Map<String, String>> out = new ArrayList<>();
            NodeList rows = doc.getElementsByTagNameNS("*", "row");
            for (int i = 0; i < rows.getLength(); i++) {
                NodeList cells = ((Element) rows.item(i)).getElementsByTagNameNS("*", "cell");
                Map<String, String> row = new ConcurrentHashMap<>();
                for (int c = 0; c < cells.getLength() && c < names.size(); c++) {
                    row.put(names.get(c), cells.item(c).getTextContent().trim());
                }
                out.add(row);
            }
            return List.copyOf(out);
        } catch (IllegalStateException e) {
            throw e;
        } catch (Exception e) {
            throw new IllegalStateException("Cannot read DVM " + path, e);
        }
    }

    /**
     * Saxon binding so the ORIGINAL XQuery runs in the golden test: processor.registerExtensionFunction(DvmLookup.saxon("lookup")).
     * Argument order mirrors lookup(); adjust to the signature the original .xqy calls (it is on the flow card).
     */
    public static ExtensionFunction saxon(String localName) {
        SequenceType str = SequenceType.makeSequenceType(ItemType.STRING, OccurrenceIndicator.ZERO_OR_ONE);
        return new ExtensionFunction() {
            @Override public QName getName() { return new QName(FUNCTION_NS, localName); }
            @Override public SequenceType getResultType() { return SequenceType.makeSequenceType(ItemType.STRING, OccurrenceIndicator.ONE); }
            @Override public SequenceType[] getArgumentTypes() { return new SequenceType[] {str, str, str, str, str}; }
            @Override public XdmValue call(XdmValue[] a) {
                return new XdmAtomicValue(lookup(s(a[0]), s(a[1]), s(a[2]), s(a[3]), s(a[4])));
            }
        };
    }

    private static String s(XdmValue v) {
        return v.size() == 0 ? null : v.itemAt(0).getStringValue();
    }
}
