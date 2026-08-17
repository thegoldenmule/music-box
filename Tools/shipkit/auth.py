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

import glob
import os
import re
from typing import Dict, List, Set

from . import config
from .report import Link, Result, blocked, fail, ok, say

KEY_LINK = Link("Create API key", "https://appstoreconnect.apple.com/access/integrations/api")
KEY_DIR = os.path.join(os.path.expanduser("~"), "private_keys")

ISSUER_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                       r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


def candidate_keys() -> List[str]:
    """Every AuthKey_*.p8 within reach, newest first.

    Apple names them all `AuthKey_<KEYID>.p8`, which makes this a search rather
    than a guess. Newest first is only a display order — it is emphatically not
    a ranking, because the most recently downloaded key is as likely to be the
    revoked one as the working one."""
    found: Set[str] = set()
    for directory in ("~/private_keys", "~/Downloads", "~/Desktop", "."):
        found.update(glob.glob(os.path.expanduser(os.path.join(directory, "AuthKey_*.p8"))))
    return sorted(found, key=os.path.getmtime, reverse=True)


def works(key_path: str, key_id: str, issuer: str) -> bool:
    """Does Apple accept this pair? One cheap authenticated call.

    The only question that matters and the only one nothing local can answer —
    a .p8 that parses, signs correctly and belongs to a revoked key is
    indistinguishable from a good one until Apple is asked."""
    from . import asc
    try:
        asc.Client(key_path, key_id, issuer).get("/v1/apps?limit=1")
        return True
    except Exception:
        return False


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
                    "Apple lets a .p8 be downloaded once. If it is gone, make a new key.",
                    links=[KEY_LINK])
    key_id = key_id_from_filename(p8_path)
    if not key_id:
        return fail("Expected Apple's filename AuthKey_<KEYID>.p8, got %s" % os.path.basename(p8_path),
                    "The key id lives only in the filename. Rename it back, or make a new key.",
                    links=[KEY_LINK])
    # Bytes, not text. A .p8 is PEM and so ASCII in practice, but a text read
    # with errors="replace" turns any byte that is not into U+FFFD and reports
    # success — storing a corrupt copy of a key Apple will not issue twice.
    with open(p8_path, "rb") as handle:
        body = handle.read()
    if b"BEGIN PRIVATE KEY" not in body:
        return fail("%s does not look like a .p8 private key" % os.path.basename(p8_path),
                    "Expected PEM text containing BEGIN PRIVATE KEY.")

    os.makedirs(KEY_DIR, mode=0o700, exist_ok=True)
    destination = os.path.join(KEY_DIR, os.path.basename(p8_path))
    if destination != p8_path:
        # Created 0600 by the open itself. Writing first and chmod-ing after
        # leaves the key world-readable for the length of the write.
        descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(body)
    os.chmod(destination, 0o600)

    try:
        env_path = cfg.write_env({
            "ASC_KEY_ID": key_id,
            "ASC_KEY_PATH": config.tildify(destination),
        })
    except config.SecretWriteRefused as refusal:
        return fail("The key is installed, but its id could not be saved", str(refusal),
                    data={"key_id": key_id, "key_path": destination})

    notes = []
    if os.path.commonpath([os.path.abspath(p8_path), cfg.root]) == cfg.root:
        # Copying it to safety does nothing about the original sitting in a repo.
        notes.append("Delete the original at %s — it is inside the repo. The copy in %s is "
                     "the one this tool uses." % (p8_path, KEY_DIR))
    needs_issuer = not cfg.asc_credentials()["issuer_id"]
    guidance = "Saved to %s. Key kept at %s." % (env_path, destination)
    if notes:
        guidance += "\n\n" + "\n".join(notes)
    if needs_issuer:
        guidance += "\n\nNext:  Tools/ship auth set-issuer <uuid>"
    return ok("API key %s imported" % key_id, guidance,
              data={"key_id": key_id, "key_path": destination, "env": env_path,
                    "needs_issuer": needs_issuer, "notes": notes},
              links=[KEY_LINK] if needs_issuer else [])


def set_issuer(cfg: config.Config, issuer: str) -> Result:
    issuer = issuer.strip()
    if not ISSUER_RE.match(issuer):
        return fail("That does not look like an Issuer ID",
                    "A UUID, at the top of the API keys page.", links=[KEY_LINK])
    try:
        env_path = cfg.write_env({"ASC_ISSUER_ID": issuer})
    except config.SecretWriteRefused as refusal:
        return fail("Could not save the Issuer ID", str(refusal))

    creds = cfg.asc_credentials()
    if creds["key_id"] and creds["key_path"]:
        if works(creds["key_path"], creds["key_id"], issuer):
            return ok("Issuer ID saved — Apple accepts key %s" % creds["key_id"],
                      data={"issuer_id": issuer, "env": env_path, "verified": True})
        return fail("Issuer ID saved, but Apple rejects it with key %s" % creds["key_id"],
                    "The key and the Issuer ID have to come from the same account, and a "
                    "revoked key fails the same way.\n  Tools/ship fix asc_key",
                    data={"issuer_id": issuer, "env": env_path, "verified": False},
                    links=[KEY_LINK])
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
    say("  key id     %s" % (creds["key_id"] or "—"))
    say("  issuer id  %s" % (creds["issuer_id"] or "—"))
    say("  key file   %s%s" % (creds["key_path"] or "—",
                               "" if not creds["key_path"]
                               else ("  (present)" if key_present else "  (MISSING)")))
    if cfg.has_asc_key():
        return ok("App Store Connect API key configured", data=data)
    missing = [name for name, value in (("key id", creds["key_id"]),
                                        ("issuer id", creds["issuer_id"]),
                                        ("key file", creds["key_path"])) if not value]
    title = ("App Store Connect API key incomplete (missing: %s)" % ", ".join(missing) if missing
             else "The configured key file is not on disk")
    # Blocked, not failed: nothing this tool can run produces a key. Apple has
    # to mint one, in a browser, for a human who is signed in.
    return blocked(title,
                "Create a key (role: App Manager, or Admin for cloud signing — the role "
                "cannot be changed later), then:\n"
                "  Tools/ship auth import ~/Downloads/AuthKey_<KEYID>.p8\n"
                "  Tools/ship auth set-issuer <uuid>",
                data=data, links=[KEY_LINK])
