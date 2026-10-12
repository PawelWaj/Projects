-- TEMPLATE: seed for the database mock (DatabaseMockTestTemplate). Copied to src/test/resources/mocks/<flow>/db-seed.sql.
-- Runs once in the Oracle test container as the test user. One block per scenario, keyed by the business key the
-- fixture uses. Values come from the recorded cases (what the logs show the flow read or wrote) or from the client's test data,
-- masked exactly like the fixtures. Never copy production rows unmasked.
-- Table DDL: take it from the target schema (DG1 / DBA), not invented here; keep column names and types identical.

CREATE TABLE {{table}} (
  {{business_key}} VARCHAR2(64) PRIMARY KEY,
  {{column_1}}     VARCHAR2(200),
  {{column_2}}     NUMBER
);

-- scenario {{scenario}}: row the flow reads (lookup)
INSERT INTO {{table}} ({{business_key}}, {{column_1}}, {{column_2}}) VALUES ('{{key_value}}', '{{value_from_recorded_case}}', 42);

-- XRef tables (cross references) are seeded the same way, e.g.
-- CREATE TABLE XREF_DATA (XREF_TABLE_NAME VARCHAR2(2000), XREF_COLUMN_NAME VARCHAR2(2000), ROW_NUMBER VARCHAR2(48),
--   VALUE VARCHAR2(2000), IS_DELETED VARCHAR2(1), LAST_MODIFIED TIMESTAMP);
-- (take the real DDL from the OSB/SOA schema of the environment; the columns above are only a placeholder)
