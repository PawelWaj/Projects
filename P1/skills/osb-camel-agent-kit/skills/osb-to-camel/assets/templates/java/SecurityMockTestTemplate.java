package {{package}}.{{project_pkg}};

import com.github.tomakehurst.wiremock.junit5.WireMockExtension;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import org.apache.camel.ProducerTemplate;
import org.apache.camel.test.spring.junit5.CamelSpringBootTest;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.RegisterExtension;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.time.Instant;
import java.util.Date;
import java.util.Map;

import static com.github.tomakehurst.wiremock.client.WireMock.*;
import static com.github.tomakehurst.wiremock.core.WireMockConfiguration.wireMockConfig;

/**
 * TEMPLATE: security mocks. Edge security (inbound JWT validation, mTLS termination) normally belongs to the gateway
 * and the mesh and is tested there (test-strategy.md, "what the suite does not prove"). Use this template only for what
 * the MODULE itself does:
 *
 *  S-01 outbound OAuth2 client credentials: the module fetches a token from the identity provider and sends it to the
 *       backend. WireMock plays both the token endpoint and the backend.
 *  S-02 inbound JWT validated in the module (only if the card says the module validates): tokens are signed in the
 *       test with a generated RSA key; WireMock serves the matching JWKS. No real identity provider, no real keys.
 *  mTLS to a backend: WireMock HTTPS with needClientAuth and test keystores from scripts/make_test_certs.sh
 *       (assets/templates/mocks/make_test_certs.sh); never real certificates in src/test.
 *
 * Secrets in tests are plain test properties (application-test.yml); the Vault Agent Injector is not mocked, the
 * properties it would write are.
 */
@CamelSpringBootTest
@SpringBootTest(classes = {{ProxyName}}Route.class)
@ActiveProfiles("test")
class {{ProxyName}}SecurityTest {

    @RegisterExtension
    static WireMockExtension idp = WireMockExtension.newInstance().options(wireMockConfig().dynamicPort()).build();

    @RegisterExtension
    static WireMockExtension backend = WireMockExtension.newInstance().options(wireMockConfig().dynamicPort()).build();

    static RSAKey signingKey;

    @BeforeAll
    static void identityProvider() throws Exception {
        signingKey = new RSAKeyGenerator(2048).keyID("test-key").generate();
        idp.stubFor(get(urlPathEqualTo("/jwks")).willReturn(okJson(new JWKSet(signingKey.toPublicJWK()).toString())));
        idp.stubFor(post(urlPathEqualTo("/token"))
            .withRequestBody(containing("grant_type=client_credentials"))
            .willReturn(okJson("{\"access_token\":\"test-access-token\",\"token_type\":\"Bearer\",\"expires_in\":300}")));
    }

    @DynamicPropertySource
    static void pointSecurityAtMocks(DynamicPropertyRegistry r) {
        r.add("osb.security.token-url", () -> idp.baseUrl() + "/token");
        r.add("osb.security.jwks-url", () -> idp.baseUrl() + "/jwks");
        r.add("osb.security.client-id", () -> "test-client");
        r.add("osb.security.client-secret", () -> "test-secret");
        r.add("osb.business.{{BusinessName}}.url", () -> backend.baseUrl() + "{{backend_path}}");
    }

    @Autowired ProducerTemplate template;

    static String signedToken(String audience, Instant expiry) throws Exception {
        SignedJWT jwt = new SignedJWT(new JWSHeader.Builder(JWSAlgorithm.RS256).keyID(signingKey.getKeyID()).build(),
            new JWTClaimsSet.Builder().issuer("{{expected_issuer}}").audience(audience).subject("test-user")
                .expirationTime(Date.from(expiry)).build());
        jwt.sign(new RSASSASigner(signingKey));
        return jwt.serialize();
    }

    /** S-01 the backend receives the token fetched with client credentials. */
    @Test
    void outboundCallCarriesClientCredentialsToken() throws Exception {
        backend.stubFor(post(urlPathEqualTo("{{backend_path}}")).willReturn(ok()));

        template.sendBody("direct:in", "{{input}}");

        idp.verify(1, postRequestedFor(urlPathEqualTo("/token")));
        backend.verify(postRequestedFor(urlPathEqualTo("{{backend_path}}")).withHeader("Authorization", equalTo("Bearer test-access-token")));
    }

    /** S-02 (only if the module validates JWT) an expired token is rejected with the fault OSB returned. */
    @Test
    void expiredTokenIsRejected() throws Exception {
        var ex = template.send("direct:in", e -> {
            e.getMessage().setBody("{{input}}");
            e.getMessage().setHeaders(Map.of("Authorization", "Bearer " + signedToken("{{audience}}", Instant.now().minusSeconds(60))));
        });

        org.assertj.core.api.Assertions.assertThat(ex.getException()).isNotNull();
    }
}
