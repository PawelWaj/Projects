package {{package}}.{{project_pkg}};

import {{package}}.support.DvmLookup;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * TEMPLATE: DVM lookup test. The exported .dvm file is the mock (src/main/resources/dvm/, unchanged from OSB, DG1).
 * One test per lookup the flow card lists: a mapped value from the recorded cases, and the default for an unmapped
 * value (OSB returns the default, it does not fail). The golden test covers the lookup inside the original XQuery by
 * registering DvmLookup.saxon(...) with its Saxon processor.
 *
 * XRef lookups are database rows: use DatabaseMockTestTemplate with XREF_DATA seed rows instead.
 */
class {{ProxyName}}LookupTest {

    /** L-01 a value seen in the recorded cases maps to the value OSB produced. */
    @Test
    void mappedValueFromRecordedCase() {
        assertThat(DvmLookup.lookup("{{dvm_name}}", "{{source_column}}", "{{recorded_source_value}}", "{{target_column}}", "{{default}}"))
            .isEqualTo("{{expected_target_value}}");
    }

    /** L-02 a value not in the map returns the default, as OSB does. */
    @Test
    void unmappedValueReturnsDefault() {
        assertThat(DvmLookup.lookup("{{dvm_name}}", "{{source_column}}", "not-in-the-map", "{{target_column}}", "{{default}}"))
            .isEqualTo("{{default}}");
    }
}
