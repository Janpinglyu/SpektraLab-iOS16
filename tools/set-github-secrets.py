#!/usr/bin/env python3
"""Set the repository's Actions secrets, from the files on disk.

    python3 tools/set-github-secrets.py <repo> <certificate.p12> <profile.mobileprovision>

The certificate's password and the team id are asked for, not taken from the
command line, so they do not end up in the shell history.

What it does, and why it is a script rather than a paragraph of instructions:

* **base64 without line breaks.** GitHub's secret store wants one line. The
  `base64` on macOS wraps at 76 characters by default and the result is
  rejected, which is a confusing way to fail.
* **the identity name and the profile name are read out of the files**, not
  typed. The identity name has to match the certificate's name exactly as
  `security find-identity` prints it, and the profile name has to match what
  Xcode shows; both are in the files themselves, and a typo in either is a
  signing failure much later.
* **the bundle id is read out of the profile**, so it cannot disagree with
  the profile the certificate was issued for.

The public key for the repository's Actions secrets is fetched and the values
are encrypted against it, which is what the API expects.

    pip install cryptography      # for the encryption
"""

from __future__ import annotations

import base64
import getpass
import json
import os
import subprocess
import sys
import urllib.request
from pathlib import Path

API = "https://api.github.com"


def api(url: str, method: str = "GET", body=None):
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if not token:
        print("GITHUB_TOKEN is not set", file=sys.stderr)
        sys.exit(1)
    headers = {
        "User-Agent": "spektralab-ios-secrets",
        "Authorization": f"token {token}",
        "Content-Type": "application/json",
        "Accept": "application/vnd.github+json",
    }
    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=120) as response:
        raw = response.read()
    return json.loads(raw) if raw else {}


def b64(data: bytes) -> str:
    """base64 as one line, which is what the secret store wants."""
    return base64.b64encode(data).decode("ascii")


def identity_name(p12: Path, password: str) -> str:
    """The certificate's name, exactly as `security` prints it."""
    # The name is in the certificate itself, and the only way to read it
    # without a keychain is to ask openssl.
    for command in (
        ["openssl", "pkcs12", "-in", str(p12), "-nokeys", "-passin", f"pass:{password}", "-legacy"],
        ["openssl", "pkcs12", "-in", str(p12), "-nokeys", "-passin", f"pass:{password}"],
    ):
        try:
            out = subprocess.run(command, capture_output=True, text=True, timeout=60)
        except FileNotFoundError:
            break
        if out.returncode != 0:
            continue
        # The subject line: "CN=Apple Development: Name (TEAMID)".
        for line in out.stdout.splitlines():
            if line.startswith("subject="):
                subject = line[len("subject="):].strip()
                for part in subject.split(","):
                    part = part.strip()
                    if part.startswith("CN="):
                        return part[3:].strip()
        # Older openssl prints "subject= /CN=..." with the same field.
        for line in out.stdout.splitlines():
            if "CN=" in line and "subject" in line:
                cn = line.split("CN=", 1)[1].split(",")[0].split("/")[0].strip()
                if cn:
                    return cn
    return ""


def profile_name_and_bundle(path: Path) -> tuple[str, str]:
    """The profile's name and the bundle id it was issued for."""
    out = subprocess.run(
        ["security", "cms", "-D", "-i", str(path)],
        capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        raise SystemExit(f"could not read the profile: {out.stderr.strip()}")
    plist = out.stdout
    name = ""
    bundle = ""
    for line in plist.splitlines():
        stripped = line.strip()
        if stripped.startswith("<key>Name</key>"):
            # The value is the next non-tag line.
            for candidate in plist.splitlines()[plist.splitlines().index(line) + 1:]:
                if candidate.strip() and not candidate.strip().startswith("<"):
                    name = candidate.strip()
                    break
            break
    for line in plist.splitlines():
        stripped = line.strip()
        if stripped.startswith("<key>application-identifier</key>"):
            for candidate in plist.splitlines()[plist.splitlines().index(line) + 1:]:
                if candidate.strip() and not candidate.strip().startswith("<"):
                    bundle = candidate.strip().split(".")[0]
                    bundle = ".".join(candidate.strip().split(".")[1:]) if "." in candidate.strip() else ""
                    break
            break
    return name, bundle


def encrypt(public_key: str, plaintext: str) -> str:
    """Encrypt a secret against the repository's public key."""
    try:
        from cryptography.hazmat.primitives.asymmetric import padding
        from cryptography.hazmat.primitives.serialization import load_pem_public_key
    except ImportError:
        raise SystemExit("pip install cryptography -- the secret has to be "
                         "encrypted against the repository's public key")
    key = load_pem_public_key(public_key.encode("utf-8"))
    ciphertext = key.encrypt(
        plaintext.encode("utf-8"),
        padding.OAEP(mgf=padding.MGF1(algorithm=padding.SHA1()),
                     algorithm=padding.SHA1(),
                     label=None))
    return base64.b64encode(ciphertext).decode("ascii")


def put_secret(repo: str, key_id: str, public_key: str, name: str, value: str) -> None:
    payload = {
        "encrypted_value": encrypt(public_key, value),
        "key_id": key_id,
    }
    api(f"{API}/repos/{repo}/actions/secrets/{name}", "PUT", payload)
    print(f"  set {name}")


def main() -> None:
    if len(sys.argv) < 4:
        print("usage: set-github-secrets.py <repo> <certificate.p12> <profile.mobileprovision>")
        print()
        print("The certificate's password is asked for interactively.")
        sys.exit(2)
    repo = sys.argv[1]
    p12 = Path(sys.argv[2])
    profile = Path(sys.argv[3])

    if not p12.exists():
        raise SystemExit(f"no such file: {p12}")
    if not profile.exists():
        raise SystemExit(f"no such file: {profile}")

    password = getpass.getpass("the certificate's password: ")

    print("reading the certificate...")
    identity = identity_name(p12, password)
    if not identity:
        print("::warning::could not read the certificate's name from the file")
        identity = input("the certificate's name (as `security find-identity` prints it): ").strip()

    print("reading the provisioning profile...")
    name, bundle = profile_name_and_bundle(profile)
    if not name:
        print("::warning::could not read the profile's name from the file")
        name = input("the profile's name: ").strip()

    # The team id is the parenthesised part of the identity name.
    team = ""
    if identity.endswith(")") and "(" in identity:
        team = identity[identity.rindex("(") + 1:-1].strip()

    print()
    print(f"  identity:   {identity}")
    print(f"  profile:    {name}")
    print(f"  team id:    {team}")
    print(f"  bundle id:  {bundle}")
    print()

    key = api(f"{API}/repos/{repo}/actions/secrets/public-key")
    print(f"encrypting for {repo}...")

    put_secret(repo, key["key_id"], key["key"], "IOS_CERTIFICATE_P12", b64(p12.read_bytes()))
    put_secret(repo, key["key_id"], key["key"], "IOS_CERTIFICATE_PASSWORD", password)
    put_secret(repo, key["key_id"], key["key"], "IOS_CERTIFICATE_IDENTITY", identity)
    put_secret(repo, key["key_id"], key["key"], "IOS_PROVISIONING_PROFILE", b64(profile.read_bytes()))
    put_secret(repo, key["key_id"], key["key"], "IOS_PROVISIONING_PROFILE_NAME", name)
    if team:
        put_secret(repo, key["key_id"], key["key"], "IOS_TEAM_ID", team)
    if bundle:
        put_secret(repo, key["key_id"], key["key"], "IOS_BUNDLE_ID", bundle)

    print()
    print("the secrets are set. Run the workflow:")
    print(f"  https://github.com/{repo}/actions/workflows/build-ios.yml")


if __name__ == "__main__":
    main()
