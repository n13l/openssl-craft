openssl crl -in crl_IDP_noIndirect_certIssuer_.der -inform DER -text -noout
openssl verify -crl_check -x509_strict -CAfile root_cert.crt -CRLfile crl_IDP_noIndirect_certIssuer_.pem ca1.crt