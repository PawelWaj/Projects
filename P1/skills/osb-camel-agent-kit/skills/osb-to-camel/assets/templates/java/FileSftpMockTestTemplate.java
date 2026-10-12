package {{package}}.{{project_pkg}};

import org.apache.camel.CamelContext;
import org.apache.camel.ConsumerTemplate;
import org.apache.camel.ProducerTemplate;
import org.apache.camel.builder.NotifyBuilder;
import org.apache.camel.test.spring.junit5.CamelSpringBootTest;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * TEMPLATE: file / FTP / SFTP transport (proxy polling a directory, or business service writing a file).
 * The route's directories and server come from properties (osb.file.<Name>.* / osb.sftp.<Name>.*), never hard-coded,
 * so the test points them at a temp folder (file) or an SFTP container (sftp). Sample files: from the client (DG1/DG2) or
 * rebuilt from logged payloads; MFL/flat-file formats need real samples (osb-action-mapping.md, mflTransform row).
 * Keep the OSB polling semantics on the card: read lock, move/delete after processing, error directory.
 */
@CamelSpringBootTest
@SpringBootTest(classes = {{ProxyName}}Route.class)
@ActiveProfiles("test")
@Testcontainers(disabledWithoutDocker = true)   // the WHOLE class is skipped without Docker (G5 NOT_RUN): if the build
                                                // machine has no Docker, move F-01/F-02 (temp folder only) to their own class
class {{ProxyName}}FileTransportIT {

    @TempDir static Path dir;

    @Container
    static GenericContainer<?> sftp = new GenericContainer<>("atmoz/sftp:alpine")      // image via the mirror
        .withCommand("test:test:::upload")
        .withExposedPorts(22);

    @DynamicPropertySource
    static void pointTransportsAtMocks(DynamicPropertyRegistry r) {
        r.add("osb.file.{{FileProxy}}.in", () -> dir.resolve("in").toString());
        r.add("osb.file.{{FileProxy}}.done", () -> dir.resolve("done").toString());
        r.add("osb.file.{{FileProxy}}.error", () -> dir.resolve("error").toString());
        r.add("osb.sftp.{{SftpService}}.uri", () -> "sftp://test@" + sftp.getHost() + ":" + sftp.getMappedPort(22)
            + "/upload?password=test&strictHostKeyChecking=no&useUserKnownHostsFile=false");   // test only
    }

    @Autowired CamelContext context;
    @Autowired ProducerTemplate producer;
    @Autowired ConsumerTemplate consumer;

    /** F-01 a dropped file is processed once and moved to done, as the OSB poller did. */
    @Test
    void droppedFileIsProcessedAndMoved() throws Exception {
        NotifyBuilder done = new NotifyBuilder(context).whenDone(1).create();
        Files.createDirectories(dir.resolve("in"));
        Files.copy(Path.of("src/test/resources/mocks/{{flow}}/files/{{sample_file}}"), dir.resolve("in/{{sample_file}}"));

        assertThat(done.matches(20, TimeUnit.SECONDS)).isTrue();
        assertThat(dir.resolve("done/{{sample_file}}")).exists();
    }

    /** F-02 an unreadable file goes to the error directory, not lost and not retried forever. */
    @Test
    void badFileGoesToErrorDirectory() throws Exception {
        NotifyBuilder done = new NotifyBuilder(context).whenDone(1).create();
        Files.createDirectories(dir.resolve("in"));
        Files.writeString(dir.resolve("in/broken.dat"), "not a valid record");

        assertThat(done.matches(20, TimeUnit.SECONDS)).isTrue();
        assertThat(dir.resolve("error/broken.dat")).exists();
    }

    /** F-03 outbound SFTP: the route writes the file OSB wrote, with the same name pattern and content. */
    @Test
    void routeWritesFileToSftp() throws Exception {
        producer.sendBody("direct:in", Files.readString(Path.of("src/test/resources/parity/{{flow}}/{{scenario}}/{{trace}}/input.payload")));

        String written = consumer.receiveBody(
            "sftp://test@" + sftp.getHost() + ":" + sftp.getMappedPort(22)
                + "/upload?password=test&strictHostKeyChecking=no&useUserKnownHostsFile=false&fileName={{expected_file_name}}",
            20_000, String.class);
        assertThat(written).isEqualTo(Files.readString(Path.of("src/test/resources/parity/{{flow}}/{{scenario}}/{{trace}}/expected-output.txt")));
    }
}
