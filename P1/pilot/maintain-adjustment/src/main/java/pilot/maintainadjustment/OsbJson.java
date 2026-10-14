package pilot.maintainadjustment;

import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.core.json.JsonReadFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.json.JsonMapper;
import org.apache.camel.Exchange;

/**
 * Helper bean for the YAML route: reads the payload the way OSB accepts it. The Splunk export showed raw control
 * characters inside strings and text after the closing brace; Jackson rejects both by default, so this bean is
 * lenient on exactly those two points and nothing else. It also lifts the scenario fields into headers.
 */
public final class OsbJson {

    static final ObjectMapper LENIENT = JsonMapper.builder()
        .enable(JsonReadFeature.ALLOW_UNESCAPED_CONTROL_CHARS)
        .disable(com.fasterxml.jackson.databind.DeserializationFeature.FAIL_ON_TRAILING_TOKENS)
        .build();

    private OsbJson() {
    }

    /** Parse leniently (control characters, trailing text ignored); fails on anything that is not JSON. */
    public static JsonNode parse(String body) {
        if (body == null || body.isBlank()) {
            throw new IllegalArgumentException("empty payload");
        }
        try (JsonParser p = LENIENT.createParser(body.strip())) {
            JsonNode node = LENIENT.readTree(p);
            if (node == null || !node.isObject()) {
                throw new IllegalArgumentException("payload is not a JSON object");
            }
            return node;
        } catch (com.fasterxml.jackson.core.JsonProcessingException e) {
            // original message only: Jackson's full message quotes the payload, which must not reach error headers/logs
            throw new IllegalArgumentException("payload is not JSON: " + e.getOriginalMessage());
        } catch (java.io.IOException e) {
            throw new IllegalArgumentException("payload could not be read");
        }
    }

    /** Route step: strict JSON body + scenario headers (businessTransaction, approvedOrRejected). */
    public static void annotate(Exchange exchange) throws Exception {
        JsonNode root = parse(exchange.getMessage().getBody(String.class));
        JsonNode data = root.path("data");
        exchange.getMessage().setHeader("businessTransaction", data.path("businessTransaction").asText(null));
        exchange.getMessage().setHeader("approvedOrRejected", data.path("approvedOrRejected").asText(null));
        exchange.getMessage().setBody(LENIENT.writeValueAsString(root));
    }
}
