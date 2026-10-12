#!/usr/bin/env bash
# TEMPLATE: test-only CA, server and client keystores for mTLS mocks (SecurityMockTestTemplate, WireMock HTTPS with
# needClientAuth). Output goes to src/test/resources/certs/. Never commit real certificates or keys; these are
# generated, self-signed and valid for 2 days. Needs keytool (JDK 21).
set -euo pipefail
OUT="${1:-src/test/resources/certs}"; PASS="${CERT_PASS:-changeit}"; DAYS=2
mkdir -p "$OUT"; cd "$OUT"; rm -f ./*.p12 ./*.crt
keytool -genkeypair -alias test-ca -keyalg RSA -keysize 2048 -dname "CN=test-ca" -ext bc:c -validity $DAYS \
  -keystore ca.p12 -storetype PKCS12 -storepass "$PASS"
keytool -exportcert -alias test-ca -keystore ca.p12 -storepass "$PASS" -rfc -file ca.crt
for who in server client; do
  keytool -genkeypair -alias "$who" -keyalg RSA -keysize 2048 -dname "CN=$who" -validity $DAYS \
    -keystore "$who.p12" -storetype PKCS12 -storepass "$PASS" -ext "SAN=dns:localhost,ip:127.0.0.1"
  keytool -certreq -alias "$who" -keystore "$who.p12" -storepass "$PASS" \
    | keytool -gencert -alias test-ca -keystore ca.p12 -storepass "$PASS" -validity $DAYS -rfc \
        -ext "SAN=dns:localhost,ip:127.0.0.1" > "$who.crt"
  keytool -importcert -noprompt -alias test-ca -file ca.crt -keystore "$who.p12" -storepass "$PASS"
  keytool -importcert -noprompt -alias "$who" -file "$who.crt" -keystore "$who.p12" -storepass "$PASS"
done
keytool -importcert -noprompt -alias test-ca -file ca.crt -keystore truststore.p12 -storetype PKCS12 -storepass "$PASS"
echo "test certificates written to $(pwd): ca, server, client, truststore (PKCS12, password from CERT_PASS)"
