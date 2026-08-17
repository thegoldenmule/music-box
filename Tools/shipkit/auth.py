"""Adopting an App Store Connect API key.

Without a key the pipeline can still run — `xcodebuild` will ride whatever Xcode
login session exists. But a session expires, cannot be used from a script, and
gives the tool no way to *ask* App Store Connect anything: no app-record check
before a fifteen-minute archive, no build-number collision check before an
upload Apple will reject, no "is it done processing yet". Everything this tool
does that is better than reading a log after the fact needs the key.

Apple names every downloaded key `AuthKey_<KEYID>.p8`, so the key id rides in
the filename and a single `auth import` configures two thirds of the pair. Only
the Issuer ID has to be pasted, because it is not in the file.

The `.p8` is copied to `~/private_keys/` — outside any repo, so it cannot be
committed by accident — and only the id and a home-relative path are written
down, into a `.env` this tool checks is gitignored first.
"""

from __future__ import annotations

import os
import re
from typing import Dict

from . import config
from .report import Link, Result, fail, ok, say

KEY_LINK = Link("Create API key", "https://appstoreconnect.apple.com/access/integrations/api")
KEY_DIR = os.path.join(os.path.expanduser("~"), "private_keys")

ISSUER_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                       r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


def key_id_from_filename(path: str) -> str:
    name = os.path.basename(path)
    if name.startswith("AuthKey_") and name.endswith(".p8"):
        candidate = name[len("AuthKey_"):-len(".p8")]
        if len(candidate) >= 6:
            return candidate
    return ""


def import_key(cfg: config.Config, p8_path: str) -> Result:
    p8_path = os.path.abspath(os.path.expanduser(p8_path))
    if not os.path.exists(p8_path):
        return fail("No such file: %s" % p8_path,
                    "Point this at the .p8 Apple downloaded — it can only be downloaded once, "
                    "so if it is gone you need a new key.", links=[KEY_LINK])
    key_id = key_id_from_filename(p8_path)
    if not key_id:
        return fail("Expected Apple's filename AuthKey_<KEYID>.p8, got %s" % os.path.basename(p8_path),
                    "The key id is only recoverable from the filename. Rename it back to exactly "
                    "what Apple downloaded, or create a new key.", links=[KEY_LINK])
    with open(p8_path, encoding="utf-8", errors="replace") as handle:
        body = handle.read()
    if "BEGIN PRIVATE KEY" not in body:
        return fail("%s does not look like a .p8 private key" % os.path.basename(p8_path))

    os.makedirs(KEY_DIR, exist_ok=True)
    destination = os.path.join(KEY_DIR, os.path.basename(p8_path))
    if destination != p8_path:
        with open(destination, "w", encoding="utf-8") as handle:
            handle.write(body)
    os.chmod(destination, 0o600)

    env_path = cfg.write_env({
        "ASC_KEY_ID": key_id,
        "ASC_KEY_PATH": config.tildify(destination),
    })
    needs_issuer = not cfg.asc_credentials()["issuer_id"]
    guidance = "Key %s is at %s (chmod 600, outside the repo).\nId and path saved to %s." % (
        key_id, destination, env_path)
    if needs_issuer:
        guidance += ("\n\nOne field left. Copy the Issuer ID from the top of the API keys page "
                     "and run:\n  Tools/ship auth set-issuer <uuid>")
    return ok("API key %s imported" % key_id, guidance,
              data={"key_id": key_id, "key_path": destination, "env": env_path,
                    "needs_issuer": needs_issuer},
              links=[KEY_LINK] if needs_issuer else [])


def set_issuer(cfg: config.Config, issuer: str) -> Result:
    issuer = issuer.strip()
    if not ISSUER_RE.match(issuer):
        return fail("That does not look like an Issuer ID",
                    "It is a UUID, like 69a6de78-1234-47e3-e053-5b8c7c11a4d1, and it sits at the "
                    "top of the API keys page with a Copy button next to it.", links=[KEY_LINK])
    env_path = cfg.write_env({"ASC_ISSUER_ID": issuer})
    return ok("Issuer ID saved", "Written to %s." % env_path,
              data={"issuer_id": issuer, "env": env_path})


def show(cfg: config.Config) -> Result:
    creds = cfg.asc_credentials()
    sources: Dict[str, str] = {}
    for name, field in (("ASC_KEY_ID", "key_id"), ("ASC_ISSUER_ID", "issuer_id"),
                        ("ASC_KEY_PATH", "key_path")):
        sources[field] = "environment" if os.environ.get(name) else (
            "%s" % cfg.env_path if creds[field] else "unset")
    key_present = bool(creds["key_path"]) and os.path.exists(creds["key_path"])
    data = {
        # The issuer id is not a secret (it identifies the team's API access, and
        # Apple shows it on a page you have to be logged in to read) but the key
        # file's *contents* are — which is why only its path appears here.
        "key_id": creds["key_id"],
        "issuer_id": creds["issuer_id"],
        "key_path": creds["key_path"],
        "key_file_present": key_present,
        "sources": sources,
        "complete": cfg.has_asc_key(),
    }
    say("")
    for label, value in (("key id", creds["key_id"] or "—"),
                         ("issuer id", creds["issuer_id"] or "—"),
                         ("key file", creds["key_path"] or "—")):
        say("  %-10s %s  %s" % (label, value, "" if label != "key file" or not creds["key_path"]
                                else ("(present)" if key_present else "(MISSING)")))
    if cfg.has_asc_key():
        return ok("App Store Connect API key configured", data=data)
    missing = [name for name, value in (("key", creds["key_id"]), ("issuer id", creds["issuer_id"]),
                                        ("key file", creds["key_path"])) if not value]
    return fail("App Store Connect API key incomplete (missing: %s)" % ", ".join(missing) if missing
                else "The configured key file is missing from disk",
                "1. Create a key: role App Manager (a Developer-role key authenticates but cannot "
                "manage signing assets)\n"
                "2. Tools/ship auth import ~/Downloads/AuthKey_<KEYID>.p8\n"
                "3. Tools/ship auth set-issuer <uuid from the top of that page>",
                data=data, links=[KEY_LINK])
