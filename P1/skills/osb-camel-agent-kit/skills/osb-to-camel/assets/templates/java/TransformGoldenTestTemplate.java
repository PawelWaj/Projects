package {{package}}.{{project_pkg}};

import net.sf.saxon.s9api.Processor;
import net.sf.saxon.s9api.QName;
import net.sf.saxon.s9api.XQueryCompiler;
import net.sf.saxon.s9api.XQueryEvaluator;
import net.sf.saxon.s9api.XdmNode;
import net.sf.saxon.s9api.XdmValue;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import org.xmlunit.builder.DiffBuilder;
import org.xmlunit.diff.Diff;

import javax.xml.transform.stream.StreamSource;
import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * TEMPLATE: golden test for one OSB transform. The expected output is never hand-written: it is what the ORIGINAL
 * query (untouched copy under src/test/resources/osb-original/, with the fn-bea shim imported) produces for the
 * fixture. The migrated query under src/main/resources/osb/ must produce the same, modulo the ignore list.
 *
 * Fixture layout: src/test/resources/fixtures/{{flow}}/transforms/{{TransformName}}/<NN>-<desc>/params/<param>.xml
 *                 ... plus ignore-fields.txt (one XPath per line) next to the fixture folders.
 */
class {{TransformName}}GoldenTest {

    static final Path FIXTURES = Path.of("src/test/resources/fixtures/{{flow}}/transforms/{{TransformName}}");
    static final Path ORIGINAL = Path.of("src/test/resources/osb-original/{{project}}/Transform/{{TransformName}}.xqy");
    static final Path MIGRATED = Path.of("src/main/resources/osb/{{project}}/Transform/{{TransformName}}.xqy");
    static final Path SHIM_DIR = Path.of("src/test/resources/osb-original/shim/");   // fn-bea-shim.xqy lives here
    static final String SHIM_IMPORT = "import module namespace fn-bea = \"http://www.bea.com/xquery/xquery-functions\" at \"fn-bea-shim.xqy\";\n";

    static Stream<Path> fixtures() throws Exception {
        try (var s = Files.list(FIXTURES)) { return s.filter(Files::isDirectory).sorted().toList().stream(); }
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("fixtures")
    void migratedEqualsOriginal(Path fixture) throws Exception {
        String expected = run(ORIGINAL, fixture, true);     // original + shim = the OSB behaviour
        String actual = run(MIGRATED, fixture, false);      // what the route will execute
        List<String> ignore = Files.exists(FIXTURES.resolve("ignore-fields.txt"))
            ? Files.readAllLines(FIXTURES.resolve("ignore-fields.txt")) : List.of();

        Diff diff = DiffBuilder.compare(expected).withTest(actual)
            .ignoreWhitespace().ignoreComments().checkForSimilar()
            .withNodeFilter(node -> ignore.stream().noneMatch(x -> x.equals(node.getLocalName())))  // simple name filter; XPath filter in the project helper
            .build();
        assertThat(diff.hasDifferences()).as(diff.fullDescription()).isFalse();
    }

    /** Compiles the query (prepending the shim import for the original), binds every params/<name>.xml as $<name>. */
    static String run(Path query, Path fixture, boolean withShim) throws Exception {
        Processor saxon = new Processor(false);
        XQueryCompiler compiler = saxon.newXQueryCompiler();
        compiler.setBaseURI(SHIM_DIR.toUri());
        String text = Files.readString(query);
        if (withShim) {
            // insert after the version declaration so the prolog stays valid
            int cut = text.indexOf(';') + 1;
            text = text.substring(0, cut) + "\n" + SHIM_IMPORT + text.substring(cut);
        }
        XQueryEvaluator ev = compiler.compile(text).load();
        Path params = fixture.resolve("params");
        if (Files.isDirectory(params)) {
            try (var s = Files.list(params)) {
                for (Path p : s.toList()) {
                    String name = p.getFileName().toString().replaceFirst("\\.(xml|txt)$", "");
                    if (p.toString().endsWith(".xml")) {
                        XdmNode doc = saxon.newDocumentBuilder().build(new StreamSource(p.toFile()));
                        ev.setExternalVariable(new QName(name), doc.axisIterator(net.sf.saxon.s9api.Axis.CHILD).next());
                    } else {
                        ev.setExternalVariable(new QName(name), new net.sf.saxon.s9api.XdmAtomicValue(Files.readString(p).trim()));
                    }
                }
            }
        }
        XdmValue result = ev.evaluate();
        return result.toString();
    }
}
