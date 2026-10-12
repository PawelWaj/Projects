package {{package}}.{{project_pkg}};

import com.icegreen.greenmail.configuration.GreenMailConfiguration;
import com.icegreen.greenmail.junit5.GreenMailExtension;
import com.icegreen.greenmail.util.GreenMailUtil;
import com.icegreen.greenmail.util.ServerSetupTest;
import jakarta.mail.internet.MimeMessage;
import org.apache.camel.CamelContext;
import org.apache.camel.ProducerTemplate;
import org.apache.camel.builder.NotifyBuilder;
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
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * TEMPLATE: email transport (proxy reading a mailbox, or business service sending mail). GreenMail runs an SMTP and
 * IMAP server inside the test JVM: no Docker, no real mail server. Alert actions with email destinations are NOT
 * reproduced by the migration (osb-action-mapping.md, alert row), so this applies only to email TRANSPORT.
 */
@CamelSpringBootTest
@SpringBootTest(classes = {{ProxyName}}Route.class)
@ActiveProfiles("test")
class {{ProxyName}}EmailTest {

    @RegisterExtension
    static GreenMailExtension mail = new GreenMailExtension(ServerSetupTest.SMTP_IMAP)
        .withConfiguration(GreenMailConfiguration.aConfig().withUser("flow@test.local", "flow", "secret"));

    @DynamicPropertySource
    static void pointMailAtGreenMail(DynamicPropertyRegistry r) {
        r.add("osb.mail.{{MailService}}.smtp", () -> "smtp://localhost:" + ServerSetupTest.SMTP.getPort() + "?username=flow&password=secret");
        r.add("osb.mail.{{MailProxy}}.imap", () -> "imap://localhost:" + ServerSetupTest.IMAP.getPort() + "?username=flow&password=secret&delete=false&unseen=true");
    }

    @Autowired CamelContext context;
    @Autowired ProducerTemplate template;

    /** E-01 outbound: the route sends the mail OSB sent (recipient, subject, body from the recorded case). */
    @Test
    void routeSendsMail() throws Exception {
        template.sendBody("direct:in", Files.readString(Path.of("src/test/resources/parity/{{flow}}/{{scenario}}/{{trace}}/input.payload")));

        assertThat(mail.waitForIncomingEmail(10_000, 1)).isTrue();
        MimeMessage m = mail.getReceivedMessages()[0];
        assertThat(m.getSubject()).isEqualTo("{{expected_subject}}");
        assertThat(GreenMailUtil.getBody(m)).contains("{{expected_body_fragment}}");
    }

    /** E-02 inbound: a mail in the mailbox is picked up once and processed like the OSB email proxy did. */
    @Test
    void routeReadsMailbox() throws Exception {
        NotifyBuilder done = new NotifyBuilder(context).whenDone(1).create();
        GreenMailUtil.sendTextEmailTest("flow@test.local", "sender@test.local", "{{inbound_subject}}", "{{inbound_body}}");

        assertThat(done.matches(20, TimeUnit.SECONDS)).isTrue();
    }
}
