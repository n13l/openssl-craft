#!/bin/bash
set -e

# Path to custom OpenSSL installation
# Adjust this to point to your local OpenSSL build
CUSTOM_OPENSSL_DIR="${CUSTOM_OPENSSL_DIR:-/hdd/osf/git/openssl}"
OPENSSL_BIN="$CUSTOM_OPENSSL_DIR/apps/openssl"
OPENSSL_LIB="$CUSTOM_OPENSSL_DIR/"

SANDBOX_DIR="./openssl_test_sandbox"
CA_DIR="$SANDBOX_DIR/ca"
CERTS_DIR="$SANDBOX_DIR/certs"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

export LD_LIBRARY_PATH="$OPENSSL_LIB:${LD_LIBRARY_PATH:-}"
export DYLD_LIBRARY_PATH="$OPENSSL_LIB:${DYLD_LIBRARY_PATH:-}" # For macOS

echo -e "${BLUE}=== Verifying Custom OpenSSL Installation ===${NC}"
if [ ! -f "$OPENSSL_BIN" ]; then
    echo -e "${RED}ERROR: OpenSSL binary not found at: $OPENSSL_BIN${NC}"
    echo -e "${YELLOW}Please set CUSTOM_OPENSSL_DIR environment variable to your OpenSSL installation path${NC}"
    echo -e "${YELLOW}Example: export CUSTOM_OPENSSL_DIR=/path/to/openssl${NC}"
    exit 1
fi

if [ ! -d "$OPENSSL_LIB" ]; then
    echo -e "${YELLOW}WARNING: OpenSSL library directory not found at: $OPENSSL_LIB${NC}"
    echo -e "${YELLOW}Continuing anyway, but you may encounter library loading issues${NC}"
fi

echo -e "${GREEN}Using OpenSSL from: $CUSTOM_OPENSSL_DIR${NC}"
echo -e "${GREEN}OpenSSL binary: $OPENSSL_BIN${NC}"
echo -e "${GREEN}Library path: $LD_LIBRARY_PATH${NC}\n"

echo -e "${BLUE}OpenSSL Version:${NC}"
"$OPENSSL_BIN" version -a
echo ""

echo -e "${BLUE}=== OpenSSL CA Sandbox Test Setup ===${NC}\n"

# Clean up previous sandbox if exists
if [ -d "$SANDBOX_DIR" ]; then
    echo "Removing existing sandbox directory..."
    rm -rf "$SANDBOX_DIR"
fi

echo -e "${GREEN}Step 1: Creating sandbox directory structure${NC}"
mkdir -p "$CA_DIR"/{private,certs,newcerts,crl}
mkdir -p "$CERTS_DIR"
touch "$CA_DIR/index.txt"
echo "01" > "$CA_DIR/serial"
echo "01" > "$CA_DIR/crlnumber"

echo -e "${GREEN}Step 2: Creating OpenSSL configuration${NC}"
cat > "$CA_DIR/openssl.cnf" << 'EOF'
[ ca ]
default_ca = CA_default

[ CA_default ]
dir              = ./ca
certs            = $dir/certs
crl_dir          = $dir/crl
new_certs_dir    = $dir/newcerts
database         = $dir/index.txt
serial           = $dir/serial
RANDFILE         = $dir/private/.rand
private_key      = $dir/private/ca.key
certificate      = $dir/certs/ca.crt
crlnumber        = $dir/crlnumber
crl              = $dir/crl/ca.crl
crl_extensions   = crl_ext
default_crl_days = 30
default_md       = sha256
preserve         = no
policy           = policy_loose
unique_subject   = no

[ policy_loose ]
countryName             = optional
stateOrProvinceName     = optional
localityName            = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ req ]
default_bits        = 2048
distinguished_name  = req_distinguished_name
string_mask         = utf8only
default_md          = sha256
x509_extensions     = v3_ca

[ req_distinguished_name ]
countryName                     = Country Name (2 letter code)
stateOrProvinceName             = State or Province Name
localityName                    = Locality Name
0.organizationName              = Organization Name
organizationalUnitName          = Organizational Unit Name
commonName                      = Common Name
emailAddress                    = Email Address

countryName_default             = US
stateOrProvinceName_default     = Test State
localityName_default            = Test City
0.organizationName_default      = Test Org
organizationalUnitName_default  = Test Unit
emailAddress_default            = test@example.com

[ v3_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, cRLSign, keyCertSign

[ v3_intermediate_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, digitalSignature, cRLSign, keyCertSign

[ usr_cert ]
basicConstraints = CA:FALSE
nsCertType = client, email
nsComment = "OpenSSL Generated Client Certificate"
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
keyUsage = critical, nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth, emailProtection
authorityInfoAccess = OCSP;URI:http://127.0.0.1:8080

[ server_cert ]
basicConstraints = CA:FALSE
nsCertType = server
nsComment = "OpenSSL Generated Server Certificate"
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer:always
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
authorityInfoAccess = OCSP;URI:http://127.0.0.1:8080

[ crl_ext ]
authorityKeyIdentifier=keyid:always

[ ocsp ]
basicConstraints = CA:FALSE
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, OCSPSigning
EOF

cd "$SANDBOX_DIR"

# Generate CA private key and certificate
echo -e "${GREEN}Step 3: Generating CA private key and self-signed certificate${NC}"
"$OPENSSL_BIN" genrsa -out ca/private/ca.key 4096
"$OPENSSL_BIN" req -config ca/openssl.cnf -key ca/private/ca.key \
    -new -x509 -days 365 -sha256 -extensions v3_ca \
    -out ca/certs/ca.crt \
    -subj "/C=US/ST=TestState/L=TestCity/O=TestOrg/OU=TestCA/CN=Test CA"

echo -e "\n${GREEN}Step 4: Issuing first certificate${NC}"
# Generate first certificate request
"$OPENSSL_BIN" genrsa -out certs/cert1.key 2048
"$OPENSSL_BIN" req -config ca/openssl.cnf -key certs/cert1.key -new -sha256 \
    -out certs/cert1.csr \
    -subj "/C=US/ST=TestState/L=TestCity/O=TestOrg/OU=TestUnit/CN=test.example.com"

# Sign the certificate
"$OPENSSL_BIN" ca -config ca/openssl.cnf -extensions server_cert \
    -days 375 -notext -md sha256 \
    -in certs/cert1.csr \
    -out certs/cert1.crt \
    -batch

echo -e "\n${GREEN}Step 5: Issuing second certificate with SAME subject${NC}"
# Generate second certificate request with SAME subject
"$OPENSSL_BIN" genrsa -out certs/cert2.key 2048
"$OPENSSL_BIN" req -config ca/openssl.cnf -key certs/cert2.key -new -sha256 \
    -out certs/cert2.csr \
    -subj "/C=US/ST=TestState/L=TestCity/O=TestOrg/OU=TestUnit/CN=test.example.com"

# Sign the second certificate (same subject, different serial)
"$OPENSSL_BIN" ca -config ca/openssl.cnf -extensions server_cert \
    -days 375 -notext -md sha256 \
    -in certs/cert2.csr \
    -out certs/cert2.crt \
    -batch

echo -e "\n${GREEN}Step 6: Generating OCSP signing certificate${NC}"
"$OPENSSL_BIN" genrsa -out ca/private/ocsp.key 2048
"$OPENSSL_BIN" req -config ca/openssl.cnf -new -sha256 \
    -key ca/private/ocsp.key \
    -out ca/ocsp.csr \
    -subj "/C=US/ST=TestState/L=TestCity/O=TestOrg/OU=TestCA/CN=OCSP Responder"

"$OPENSSL_BIN" ca -config ca/openssl.cnf -extensions ocsp \
    -days 375 -notext -md sha256 \
    -in ca/ocsp.csr \
    -out ca/certs/ocsp.crt \
    -batch

# Display certificate information
echo -e "\n${BLUE}=== Certificate Information ===${NC}"
echo -e "\n${GREEN}Certificate 1 (Serial: 01):${NC}"
"$OPENSSL_BIN" x509 -in certs/cert1.crt -noout -serial -subject

echo -e "\n${GREEN}Certificate 2 (Serial: 02):${NC}"
"$OPENSSL_BIN" x509 -in certs/cert2.crt -noout -serial -subject

echo -e "\n${BLUE}=== Environment Variables for Testing ===${NC}"
echo -e "${YELLOW}Export these in another terminal to use the same OpenSSL:${NC}"
echo -e "export LD_LIBRARY_PATH=\"$OPENSSL_LIB:\$LD_LIBRARY_PATH\""
echo -e "export DYLD_LIBRARY_PATH=\"$OPENSSL_LIB:\$DYLD_LIBRARY_PATH\""
echo -e "export PATH=\"$CUSTOM_OPENSSL_DIR/bin:\$PATH\""
echo ""

echo -e "\n${BLUE}=== Starting OCSP Server ===${NC}"
echo "OCSP server will listen on http://127.0.0.1:8080"
echo "Press Ctrl+C to stop the server"
echo ""

"$OPENSSL_BIN" ocsp -index ca/index.txt \
    -port 8080 \
    -rsigner ca/certs/ocsp.crt \
    -rkey ca/private/ocsp.key \
    -CA ca/certs/ca.crt \
    -text