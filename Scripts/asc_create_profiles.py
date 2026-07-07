#!/usr/bin/env python3
"""Create App Store provisioning profiles for the three Fortiche bundle IDs,
referencing a given distribution certificate, and install them locally.

  <venv>/bin/python Scripts/asc_create_profiles.py <KEY_ID> <ISSUER_ID> <p8> <cert.cer>

Prints the bundle-id → profile-name mapping for ExportOptions.plist.
"""
import base64
import subprocess
import sys
import time
import uuid
from pathlib import Path

import jwt
import requests
from cryptography import x509

KEY_ID, ISSUER_ID, P8_PATH, CERT_PATH = sys.argv[1:5]
API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_IDS = [
    "com.davidruiz.fortiche",
    "com.davidruiz.fortiche.watchkitapp",
    "com.davidruiz.fortiche.widgets",
]
PROFILES_DIR = Path.home() / "Library/MobileDevice/Provisioning Profiles"


def token() -> str:
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER_ID, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        Path(P8_PATH).read_text(), algorithm="ES256",
        headers={"kid": KEY_ID, "typ": "JWT"})


def main() -> int:
    hdr = {"Authorization": f"Bearer {token()}"}

    # Match the local cert to its ASC certificate resource by serial number.
    cert = x509.load_der_x509_certificate(Path(CERT_PATH).read_bytes())
    want_serial = format(cert.serial_number, "X")
    certs = requests.get(f"{API}/certificates?limit=200", headers=hdr).json()["data"]
    cert_id = None
    for c in certs:
        content = c["attributes"].get("certificateContent")
        if not content:
            continue
        der = base64.b64decode(content)
        if format(x509.load_der_x509_certificate(der).serial_number, "X") == want_serial:
            cert_id = c["id"]
            break
    if not cert_id:
        print("could not match local cert to an ASC certificate")
        return 1

    # Map bundle-id identifier strings to their ASC resource ids.
    bundle_res = {b["attributes"]["identifier"]: b["id"]
                  for b in requests.get(f"{API}/bundleIds?limit=200", headers=hdr).json()["data"]}

    PROFILES_DIR.mkdir(parents=True, exist_ok=True)
    mapping = {}
    for bid in BUNDLE_IDS:
        if bid not in bundle_res:
            print(f"bundle id not registered in ASC: {bid}")
            return 1
        name = f"Fortiche AppStore {bid.split('.')[-1]} {uuid.uuid4().hex[:6]}"
        resp = requests.post(f"{API}/profiles", headers=hdr, json={"data": {
            "type": "profiles",
            "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle_res[bid]}},
                "certificates": {"data": [{"type": "certificates", "id": cert_id}]},
            }}})
        if resp.status_code not in (200, 201):
            print(f"profile creation failed for {bid}:", resp.status_code, resp.text[:300])
            return 1
        data = resp.json()["data"]
        content = base64.b64decode(data["attributes"]["profileContent"])
        # Install under the profile's UUID so Xcode picks it up.
        uuid_val = data["attributes"]["uuid"]
        (PROFILES_DIR / f"{uuid_val}.mobileprovision").write_bytes(content)
        mapping[bid] = name
        print(f"created + installed: {bid} -> {name}")

    print("\nExportOptions provisioningProfiles mapping:")
    for bid, name in mapping.items():
        print(f"  {bid} = {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
