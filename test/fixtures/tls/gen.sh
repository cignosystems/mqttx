#!/bin/sh
# Regenerates the TLS fixtures used by test/mqttx/client/tls_test.exs:
#
#   ca.pem          a private CA (EC P-256, self-signed, valid 100 years)
#   server.pem      a server certificate for DNS name `localhost`, signed by it
#   server-key.pem  the server's private key
#
# The certificate deliberately names ONLY `localhost`, so connecting to
# 127.0.0.1 must fail the hostname check. The CA key is not kept: a new CA is
# made on every run, and no real system trusts it.
set -eu
cd "$(dirname "$0")"

openssl ecparam -name prime256v1 -genkey -noout -out ca-key.pem
openssl req -x509 -new -key ca-key.pem -sha256 -days 36500 \
  -subj "/CN=MqttX Test CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -out ca.pem

openssl ecparam -name prime256v1 -genkey -noout -out server-key.pem
openssl req -new -key server-key.pem -subj "/CN=localhost" -out server.csr
printf 'subjectAltName=DNS:localhost\nbasicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyAgreement\nextendedKeyUsage=serverAuth\n' > ext.cnf
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial \
  -days 36500 -sha256 -extfile ext.cnf -out server.pem

openssl verify -CAfile ca.pem server.pem
rm -f ca-key.pem ca.srl server.csr ext.cnf
