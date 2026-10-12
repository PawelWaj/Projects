package {{package}}.{{project_pkg}};

import org.apache.camel.ProducerTemplate;
import org.apache.camel.test.spring.junit5.CamelSpringBootTest;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.oracle.OracleContainer;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * TEMPLATE: database mock for flows that use a JCA DB adapter (select, insert, update, stored procedure, polling)
 * or fn-bea:execute-sql. The route keeps the SAME SQL statement as the .jca / XQuery (osb-transport-mapping.md), so the
 * test runs that statement against a real Oracle in a container, seeded with rows that reproduce the recorded cases.
 *
 * Seed data: src/test/resources/mocks/{{flow}}/db-seed.sql (assets/templates/mocks/db-seed.sql). Rows come from the
 * recorded cases (values the logs show the flow read or wrote) or from the client's test data; personal data masked as in the
 * fixtures. One row set per scenario, keyed by the business key the fixture uses.
 *
 * Without Docker: switch to the H2 variant (profile "test-h2", MODE=Oracle) ONLY for plain SELECT/INSERT lookups.
 * Stored procedures, sequences, ROWNUM paging, MERGE and logical-delete polling need the Oracle container; the test
 * class then reports NOT_RUN through gate G5 instead of passing on H2.
 *
 * XRef (cross-reference) tables are a database too: seed XREF_DATA rows here and test them the same way.
 */
@CamelSpringBootTest
@SpringBootTest(classes = {{ProxyName}}Route.class)
@ActiveProfiles("test")
@Testcontainers
class {{ProxyName}}DatabaseIT {

    @Container
    static OracleContainer oracle = new OracleContainer("gvenzl/oracle-free:slim-faststart")   // image via the mirror
        .withInitScript("mocks/{{flow}}/db-seed.sql");

    @DynamicPropertySource
    static void pointDataSourceAtContainer(DynamicPropertyRegistry r) {
        // mirrors the production keys of the module; the JCA adapter's JNDI name maps to this data source on the card
        r.add("spring.datasource.url", oracle::getJdbcUrl);
        r.add("spring.datasource.username", oracle::getUsername);
        r.add("spring.datasource.password", oracle::getPassword);
    }

    @Autowired ProducerTemplate template;
    @Autowired JdbcTemplate jdbc;

    String fixture(String n) throws Exception {
        return Files.readString(Path.of("src/test/resources/parity/{{flow}}").resolve(n));
    }

    /** D-01 lookup: the route reads the seeded row and puts the value where the OSB pipeline put it. */
    @Test
    void lookupReadsSeededRow() throws Exception {
        String out = template.requestBodyAndHeaders("direct:in", fixture("{{scenario}}/{{trace}}/input.payload"),
            Map.of("traceId", "test-trace"), String.class);

        assertThat(out).contains("{{expected_value_from_seed}}");
    }

    /** D-02 write: after the route, the row exists with the values OSB wrote (from the recorded case). */
    @Test
    void writeInsertsRowAsOsbDid() throws Exception {
        template.sendBodyAndHeaders("direct:in", fixture("{{scenario}}/{{trace}}/input.payload"), Map.of("traceId", "test-trace"));

        Map<String, Object> row = jdbc.queryForMap("SELECT {{columns}} FROM {{table}} WHERE {{business_key}} = ?", "{{key_value}}");
        assertThat(row).containsEntry("{{COLUMN}}", "{{expected}}");
    }

    /** D-03 database down or constraint violation: the flow takes the OSB error path (error queue + fault code). */
    @Test
    void constraintViolationTakesErrorPath() throws Exception {
        jdbc.update("INSERT INTO {{table}} ({{business_key}}) VALUES (?)", "{{duplicate_key}}");   // force the violation

        var ex = template.send("direct:in", e -> e.getMessage().setBody(fixture("{{scenario}}/{{trace}}/input.payload")));

        assertThat(ex.getMessage().getHeader("osb.fault.errorCode", String.class)).isEqualTo("{{osb_fault_code}}");
    }
}
