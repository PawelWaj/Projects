package {{package}}.{{project_pkg}};

import com.github.tomakehurst.wiremock.junit5.WireMockExtension;
import org.apache.camel.ProducerTemplate;
import org.apache.camel.component.cxf.common.message.CxfConstants;
import org.apache.camel.test.spring.junit5.CamelSpringBootTest;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.extension.RegisterExtension;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.xmlunit.builder.DiffBuilder;
import org.xmlunit.diff.Diff;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.stream.Stream;

import static com.github.tomakehurst.wiremock.client.WireMock.*;
import static com.github.tomakehurst.wiremock.core.WireMockConfiguration.wireMockConfig;
import static org.assertj.core.api.Assertions.assertThat;

/**
 * TEMPLATE: parity replay. Each folder under src/test/resources/parity/{{flow}}/<NN>/ holds a recorded OSB exchange:
 *   request.xml, response.xml, backend/<BusinessService>/request.xml + response.xml, and optionally ignore-fields.txt.
 * WireMock replays the backend responses; the route's response must be similar to the recorded OSB response, and the
 * request the route sent to each backend must be similar to the recorded backend request.
 * Without fixtures the test is skipped with a visible reason: parity is then "not proven", and the record says so.
 */
@CamelSpringBootTest
@SpringBootTest(classes = {{ProxyName}}Route.class)
@ActiveProfiles("test")
class {{ProxyName}}ParityReplayTest {

    static final Path PARITY = Path.of("src/test/resources/parity/{{flow}}");

    @RegisterExtension
    static WireMockExtension backends = WireMockExtension.newInstance().options(wireMockConfig().dynamicPort()).build();

    @DynamicPropertySource
    static void backendsToWireMock(DynamicPropertyRegistry r) {
        r.add("osb.business.ContributorCoreBS.url", () -> backends.baseUrl() + "/ContributorService");
        r.add("osb.business.MemberLookupBS.url", () -> backends.baseUrl() + "/MemberLookup/v2");
    }

    @Autowired ProducerTemplate template;

    static Stream<Path> recordings() throws Exception {
        if (!Files.isDirectory(PARITY)) return Stream.empty();
        try (var s = Files.list(PARITY)) { return s.filter(Files::isDirectory).sorted().toList().stream(); }
    }

    @ParameterizedTest(name = "recorded exchange {0}")
    @MethodSource("recordings")
    void replayedExchange_matchesRecordedResponse(Path rec) throws Exception {
        Assumptions.assumeTrue(Files.exists(rec.resolve("response.xml")), "no recorded OSB response in " + rec);
        backends.resetAll();
        // replay every recorded backend response
        try (var s = Files.list(rec.resolve("backend"))) {
            for (Path b : s.toList()) {
                String path = b.getFileName().toString().equals("ContributorCoreBS") ? "/ContributorService" : "/MemberLookup/v2";
                backends.stubFor(post(urlPathEqualTo(path)).willReturn(okXml(Files.readString(b.resolve("response.xml")))));
            }
        }
        String operation = Files.readString(rec.resolve("operation.txt")).trim();
        var exchange = template.send("cxf:bean:{{proxyName}}Endpoint?dataFormat=PAYLOAD", e -> {
            e.getMessage().setBody(Files.readString(rec.resolve("request.xml")));
            e.getMessage().setHeader(CxfConstants.OPERATION_NAME, operation);
        });
        List<String> ignore = Files.exists(rec.resolve("ignore-fields.txt")) ? Files.readAllLines(rec.resolve("ignore-fields.txt")) : List.of();

        Diff diff = DiffBuilder.compare(Files.readString(rec.resolve("response.xml")))
            .withTest(exchange.getMessage().getBody(String.class))
            .ignoreWhitespace().ignoreComments().checkForSimilar()
            .withNodeFilter(n -> ignore.stream().noneMatch(x -> x.equals(n.getLocalName())))
            .build();
        assertThat(diff.hasDifferences()).as(diff.fullDescription()).isFalse();

        // and the backend saw what OSB sent it
        try (var s = Files.list(rec.resolve("backend"))) {
            for (Path b : s.toList()) {
                String path = b.getFileName().toString().equals("ContributorCoreBS") ? "/ContributorService" : "/MemberLookup/v2";
                var sent = backends.findAll(postRequestedFor(urlPathEqualTo(path)));
                assertThat(sent).as("backend " + b.getFileName() + " was called").isNotEmpty();
                Diff bd = DiffBuilder.compare(Files.readString(b.resolve("request.xml"))).withTest(sent.get(0).getBodyAsString())
                    .ignoreWhitespace().checkForSimilar().withNodeFilter(n -> ignore.stream().noneMatch(x -> x.equals(n.getLocalName()))).build();
                assertThat(bd.hasDifferences()).as(bd.fullDescription()).isFalse();
            }
        }
    }
}
