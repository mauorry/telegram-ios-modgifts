#!/usr/bin/env python3
"""Extend the expiry of the bundled fake-codesigning profiles and re-sign them.

Upstream ships nine .mobileprovision files under build-system/fake-codesigning/profiles.
They are fake (a CMS blob around a plist signed with certs/SelfSigned.p12), but Bazel's
plisttool refuses to build once ExpirationDate is in the past:

    ERROR: provisioning profile ExpirationDate ("2026-10-30T17:06:30") is in the past.

Every profile in the pinned revision expires on 2026-10-30, so the pipeline stops building
on a fixed day even though no code changed. A byte-level date edit does not work: Make.py
extracts each profile with `openssl smime -inform der -verify -noverify`, so the CMS signature
is checked on every build. This script decodes the payload, bumps the expiry year to 2036,
re-signs with the repository's own self-signed identity, and verifies the result with the exact
command Make.py uses. Nothing else in the payload is touched.

Usage: resign_profiles.py <telegram-ios-source-dir>
"""

import pathlib
import re
import subprocess
import sys
import tempfile

PROFILES = [
    "Telegram", "Intents", "NotificationContent", "NotificationService",
    "Share", "WatchApp", "WatchExtension", "Widget", "BroadcastUpload",
]
TARGET_YEAR = b"2036"
DATE_RE = re.compile(rb"(<key>ExpirationDate</key>\s*<date>)(\d{4})(-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)")


def run(args, **kwargs):
    return subprocess.run(args, capture_output=True, **kwargs)


def main():
    if len(sys.argv) != 2:
        print("usage: resign_profiles.py <telegram-ios-source-dir>", file=sys.stderr)
        return 2
    source = pathlib.Path(sys.argv[1])
    profiles_dir = source / "build-system" / "fake-codesigning" / "profiles"
    certs_dir = source / "build-system" / "fake-codesigning" / "certs"
    p12 = certs_dir / "SelfSigned.p12"
    if not p12.exists():
        print(f"missing {p12}", file=sys.stderr)
        return 1

    # Import the self-signed identity into a temporary keychain so `security cms -S` can sign.
    keychain = "modgift-resign.keychain"
    keychain_password = "secret"
    run(["security", "delete-keychain", keychain])
    r = run(["security", "create-keychain", "-p", keychain_password, keychain])
    if r.returncode != 0:
        print(r.stderr.decode(errors="replace"), file=sys.stderr)
        return 1
    existing = run(["security", "list-keychains", "-d", "user"], check=True).stdout.decode().replace('"', '')
    run(["security", "list-keychains", "-d", "user", "-s", keychain, existing], check=True)
    run(["security", "set-keychain-settings", keychain])
    run(["security", "unlock-keychain", "-p", keychain_password, keychain])
    r = run(["security", "import", str(p12), "-k", keychain, "-P", "", "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"])
    if r.returncode != 0:
        print("import failed: " + r.stderr.decode(errors="replace"), file=sys.stderr)
        return 1
    # Find the signing identity: extract the certificate CN from the p12 with openssl (the same
    # approach the repo's own GenerateProfiles.py uses). `security find-identity -p codesigning`
    # does not list this self-signed cert (no codesigning trust), so do not rely on it.
    cert_pem = run(["openssl", "pkcs12", "-in", str(p12), "-passin", "pass:", "-nokeys", "-legacy"]).stdout
    subj = subprocess.run(["openssl", "x509", "-noout", "-subject", "-nameopt", "oneline,-esc_msb"],
                          input=cert_pem, capture_output=True).stdout.decode()
    identity = None
    if "CN = " in subj:
        identity = subj.split("CN = ")[-1].split(",")[0].strip()
    if not identity:
        print(f"could not extract CN from p12, subject={subj!r}", file=sys.stderr)
        return 1
    print(f"signing identity: {identity}")

    for name in PROFILES:
        path = profiles_dir / f"{name}.mobileprovision"
        if not path.exists():
            print(f"skip missing {path}")
            continue
        der = path.read_bytes()
        decoded = run(["openssl", "smime", "-inform", "der", "-verify", "-noverify", "-in", str(path)])
        if decoded.returncode != 0:
            print(f"decode failed for {name}: {decoded.stderr.decode(errors='replace')}", file=sys.stderr)
            return 1
        payload = decoded.stdout
        new_payload, n = DATE_RE.subn(lambda mm: mm.group(1) + TARGET_YEAR + mm.group(3), payload)
        if n == 0:
            print(f"no ExpirationDate found in {name}", file=sys.stderr)
            return 1
        with tempfile.NamedTemporaryFile(suffix=".plist", delete=False) as tf:
            tf.write(new_payload)
            plist_path = tf.name
        out_path = str(path)
        signed = run(["security", "cms", "-S", "-k", keychain, "-N", identity, "-i", plist_path, "-o", out_path])
        pathlib.Path(plist_path).unlink(missing_ok=True)
        if signed.returncode != 0:
            print(f"sign failed for {name}: {signed.stderr.decode(errors='replace')}", file=sys.stderr)
            return 1
        # Verify with the exact command Make.py uses.
        verify = run(["openssl", "smime", "-inform", "der", "-verify", "-noverify", "-in", out_path])
        if verify.returncode != 0:
            print(f"verify failed for {name}: {verify.stderr.decode(errors='replace')}", file=sys.stderr)
            return 1
        if b"2036" not in verify.stdout:
            print(f"expiry not bumped for {name}", file=sys.stderr)
            return 1
        print(f"resigned {name} -> 2036")

    run(["security", "delete-keychain", keychain])
    print("all profiles resigned")
    return 0


if __name__ == "__main__":
    sys.exit(main())
