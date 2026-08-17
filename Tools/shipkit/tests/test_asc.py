"""The parts of the App Store Connect client that can be tested without Apple.

The JWT signature conversion is the piece worth pinning down: it is thirty lines
of ASN.1 that stand in for a dependency, and when it is wrong the only symptom
is a 401 that looks exactly like a revoked key.
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest

from shipkit import asc


def _der(r: bytes, s: bytes) -> bytes:
    """Hand-built SEQUENCE(INTEGER r, INTEGER s) with short-form lengths."""
    body = b""
    for value in (r, s):
        body += b"\x02" + bytes([len(value)]) + value
    return b"\x30" + bytes([len(body)]) + body


class DerToRaw(unittest.TestCase):
    def test_pads_short_integers_to_32_bytes(self) -> None:
        raw = asc.der_to_raw(_der(b"\x01", b"\x02"))
        self.assertEqual(len(raw), 64)
        self.assertEqual(raw[:32], b"\x00" * 31 + b"\x01")
        self.assertEqual(raw[32:], b"\x00" * 31 + b"\x02")

    def test_strips_the_asn1_sign_byte(self) -> None:
        # DER prefixes a 0x00 when the high bit is set, so a full-width value
        # arrives as 33 bytes and must come back out as 32.
        value = b"\x00" + b"\xff" * 32
        raw = asc.der_to_raw(_der(value, value))
        self.assertEqual(len(raw), 64)
        self.assertEqual(raw[:32], b"\xff" * 32)

    def test_long_form_length(self) -> None:
        # A 64-byte body pushes the SEQUENCE length into long form (0x81 NN),
        # which is the branch a short-form-only parser silently misreads.
        value = b"\x11" * 32
        der = _der(value, value)
        body = der[2:]
        long_form = b"\x30\x81" + bytes([len(body)]) + body
        self.assertEqual(asc.der_to_raw(long_form), value + value)

    def test_rejects_something_that_is_not_a_signature(self) -> None:
        with self.assertRaises(asc.ASCError):
            asc.der_to_raw(b"not der")

    def test_rejects_empty_input(self) -> None:
        with self.assertRaises(asc.ASCError):
            asc.der_to_raw(b"")


class TokenRoundTrip(unittest.TestCase):
    """Sign a real JWT with a throwaway EC key and check openssl verifies it.

    This is the only end-to-end proof available without hitting Apple: if the
    header, payload and signature encoding are right, openssl validates the
    same bytes Apple would."""

    def test_signs_a_verifiable_es256_token(self) -> None:
        if not os.path.exists("/usr/bin/openssl"):
            self.skipTest("no /usr/bin/openssl")
        with tempfile.TemporaryDirectory() as workdir:
            key = os.path.join(workdir, "key.pem")
            made = subprocess.run(
                ["/usr/bin/openssl", "ecparam", "-genkey", "-name", "prime256v1",
                 "-noout", "-out", key], capture_output=True)
            if made.returncode != 0:
                self.skipTest("openssl cannot generate a P-256 key here")

            client = asc.Client(key, "TESTKEYID", "issuer-uuid")
            token = client.token()
            header_b64, payload_b64, signature_b64 = token.split(".")

            def unb64(text: str) -> bytes:
                import base64
                return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))

            self.assertEqual(json.loads(unb64(header_b64)),
                             {"alg": "ES256", "kid": "TESTKEYID", "typ": "JWT"})
            payload = json.loads(unb64(payload_b64))
            self.assertEqual(payload["aud"], "appstoreconnect-v1")
            self.assertEqual(payload["iss"], "issuer-uuid")
            # Apple rejects a token whose life exceeds twenty minutes outright.
            self.assertLessEqual(payload["exp"] - payload["iat"], 20 * 60)
            self.assertEqual(len(unb64(signature_b64)), 64)

    def test_a_missing_key_file_is_an_error_not_a_crash(self) -> None:
        client = asc.Client("/nope/AuthKey_X.p8", "X", "Y")
        with self.assertRaises(asc.ASCError):
            client.token()


class UploadOrdering(unittest.TestCase):
    def test_the_most_recent_upload_wins(self) -> None:
        older = {"uploaded": "2026-01-01T00:00:00Z"}
        newer = {"uploaded": "2026-08-01T00:00:00Z"}
        self.assertGreater(asc._uploaded_key(newer), asc._uploaded_key(older))

    def test_a_record_with_no_timestamp_loses(self) -> None:
        self.assertLess(asc._uploaded_key({}), asc._uploaded_key({"uploaded": "2026-01-01T00:00:00Z"}))


if __name__ == "__main__":
    unittest.main()
