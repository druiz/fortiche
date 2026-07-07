#!/usr/bin/env python3
"""Create an Apple Distribution certificate via the App Store Connect API and
import it into the login keychain, so `xcodebuild -exportArchive` can sign
without a pre-existing cert or interactive cloud signing.

Run with the venv python that has cryptography/pyjwt/requests installed:
  <venv>/bin/python Scripts/asc_create_cert.py <KEY_ID> <ISSUER_ID> <p8_path>

Idempotent-ish: if a DISTRIBUTION cert already exists on the account this will
create an additional one (Apple allows a small number). The matching private
key is generated here and paired into a .p12 before keychain import.
"""
import base64
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import jwt
import requests
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509 import (CertificateSigningRequestBuilder, Name,
                               NameAttribute)
from cryptography.x509.oid import NameOID

KEY_ID, ISSUER_ID, P8_PATH = sys.argv[1], sys.argv[2], sys.argv[3]
API = "https://api.appstoreconnect.apple.com/v1"


def token() -> str:
    key = Path(P8_PATH).read_text()
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER_ID, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": KEY_ID, "typ": "JWT"},
    )


def main() -> int:
    hdr = {"Authorization": f"Bearer {token()}"}

    # 1. Generate an RSA private key + CSR (Apple signs the CSR into a cert).
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    csr = (
        CertificateSigningRequestBuilder()
        .subject_name(Name([NameAttribute(NameOID.COMMON_NAME, "Fortiche Distribution")]))
        .sign(private_key, hashes.SHA256())
    )
    csr_pem = csr.public_bytes(serialization.Encoding.PEM).decode()

    # 2. Ask ASC to issue a DISTRIBUTION (Apple Distribution) certificate.
    #    csrContent is the PEM text itself (headers included), not re-encoded.
    resp = requests.post(
        f"{API}/certificates",
        headers=hdr,
        json={"data": {"type": "certificates", "attributes": {
            "certificateType": "DISTRIBUTION", "csrContent": csr_pem}}},
    )
    if resp.status_code not in (200, 201):
        print("certificate creation failed:", resp.status_code, resp.text[:500])
        return 1
    cert_b64 = resp.json()["data"]["attributes"]["certificateContent"]
    cert_der = base64.b64decode(cert_b64)

    # 3. Persist cert + key so a re-run doesn't burn another Apple cert slot,
    #    then build a passwordless .p12 and import into the login keychain.
    out = Path(sys.argv[4]) if len(sys.argv) > 4 else Path(tempfile.mkdtemp())
    out.mkdir(parents=True, exist_ok=True)
    (out / "cert.cer").write_bytes(cert_der)
    (out / "key.pem").write_bytes(private_key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption(),
    ))
    subprocess.run(["openssl", "x509", "-inform", "DER", "-in", str(out / "cert.cer"),
                    "-out", str(out / "cert.pem")], check=True)
    subprocess.run(["openssl", "pkcs12", "-export", "-legacy",
                    "-inkey", str(out / "key.pem"), "-in", str(out / "cert.pem"),
                    "-out", str(out / "dist.p12"), "-passout", "pass:"], check=True)
    print(f"cert issued by Apple; artifacts in {out}")
    print("Now import with:  security import", out / "dist.p12", "-k ~/Library/Keychains/login.keychain-db -P '' -A")
    return 0


if __name__ == "__main__":
    sys.exit(main())
