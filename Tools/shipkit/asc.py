"""A small App Store Connect API client.

Stdlib only, which means no `cryptography` package for the ES256 JWT Apple
requires. `/usr/bin/openssl` signs it instead and the DER signature is converted
to the raw r‖s form the JWT spec wants — about thirty lines, against a
dependency that would have to be installed before the tool could tell you why
your release is stuck.

Everything here is read-only except three operations, each of which is an
ordinary reversible thing a developer does in the portal by hand: registering a
bundle id, creating an internal TestFlight group, and answering the export
compliance question on a build.

What this deliberately cannot do is create an app record — that is genuinely
absent from Apple's public API, so the tool's job there is to say so clearly
and hand over a link, not to fail at an upload twenty minutes later.
"""

from __future__ import annotations

import base64
import json
import os
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional

API = "https://api.appstoreconnect.apple.com"

# Apple caps a token's life at 20 minutes and rejects anything longer outright.
TOKEN_LIFETIME = 19 * 60


class ASCError(Exception):
    """An App Store Connect call did not work.

    `status` carries the HTTP code when there was one — 401 means the key is
    wrong or revoked and no amount of retrying fixes it, which is a different
    conversation with the user than a 503."""

    def __init__(self, message: str, status: int = 0):
        super().__init__(message)
        self.status = status


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(der: bytes) -> bytes:
    """SEQUENCE(INTEGER r, INTEGER s) → the 64-byte r‖s a JWS signature is.

    openssl emits DER; JWT wants fixed-width halves. Each integer is stripped of
    its sign padding and re-padded to 32 bytes, which is the whole conversion."""

    def read_len(buf: bytes, index: int):
        length = buf[index]
        index += 1
        if length & 0x80:
            count = length & 0x7F
            length = int.from_bytes(buf[index:index + count], "big")
            index += count
        return length, index

    if not der or der[0] != 0x30:
        raise ASCError("openssl did not return a DER signature")
    _, index = read_len(der, 1)
    out = b""
    for _ in range(2):
        if der[index] != 0x02:
            raise ASCError("malformed DER signature")
        index += 1
        length, index = read_len(der, index)
        value = der[index:index + length].lstrip(b"\x00")
        index += length
        out += value.rjust(32, b"\x00")
    return out


class Client:
    def __init__(self, key_path: str, key_id: str, issuer_id: str, individual: bool = False):
        self.key_path = os.path.expanduser(key_path)
        self.key_id = key_id
        self.issuer_id = issuer_id
        # Apple issues two kinds of key and they need different payloads: a team
        # key carries `iss` (the issuer UUID), an individual key carries
        # `sub: "user"` and no `iss` at all. Nothing in the key or the filename
        # says which you have — the only signal is a 401 — so start with the
        # common form and flip once if Apple refuses it.
        self.individual = individual
        self._flipped = False
        self._token = ""
        self._token_expires = 0.0

    # ── auth ──────────────────────────────────────────────────────────────────

    def token(self) -> str:
        if self._token and time.time() < self._token_expires - 60:
            return self._token
        if not os.path.exists(self.key_path):
            raise ASCError("API key file missing: %s" % self.key_path)
        header = {"alg": "ES256", "kid": self.key_id, "typ": "JWT"}
        now = int(time.time())
        payload = {"iat": now, "exp": now + TOKEN_LIFETIME, "aud": "appstoreconnect-v1"}
        if self.individual:
            payload["sub"] = "user"
        else:
            payload["iss"] = self.issuer_id
        signing_input = (_b64url(json.dumps(header, separators=(",", ":")).encode())
                         + "." + _b64url(json.dumps(payload, separators=(",", ":")).encode()))
        with tempfile.NamedTemporaryFile() as handle:
            handle.write(signing_input.encode())
            handle.flush()
            try:
                der = subprocess.run(
                    ["/usr/bin/openssl", "dgst", "-sha256", "-sign", self.key_path, handle.name],
                    capture_output=True, check=True).stdout
            except subprocess.CalledProcessError as error:
                raise ASCError("openssl could not sign with %s: %s"
                               % (self.key_path, error.stderr.decode(errors="replace").strip()))
        self._token = signing_input + "." + _b64url(der_to_raw(der))
        self._token_expires = now + TOKEN_LIFETIME
        return self._token

    # ── transport ─────────────────────────────────────────────────────────────

    def _request(self, method: str, path: str, payload: Optional[Dict[str, Any]] = None,
                 attempt: int = 0) -> Dict[str, Any]:
        headers = {"Authorization": "Bearer " + self.token()}
        body = None
        if payload is not None:
            headers["Content-Type"] = "application/json"
            body = json.dumps(payload).encode()
        request = urllib.request.Request(API + path, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            text = error.read().decode(errors="replace")
            # Apple's error bodies are a JSON envelope whose `detail` is the only
            # part worth showing; the rest is a link to the same docs every time.
            detail = text[:400]
            try:
                errors = json.loads(text).get("errors") or []
                if errors:
                    detail = "; ".join(
                        "%s — %s" % (e.get("title", ""), e.get("detail", "")) for e in errors)
            except ValueError:
                pass
            # A 401 on the first call may just mean this is an individual key
            # rather than a team key: same file, different JWT payload. Flip
            # once and retry before telling anyone their key is revoked.
            if error.code == 401 and not self._flipped:
                self._flipped = True
                self.individual = not self.individual
                self._token = ""
                return self._request(method, path, payload, attempt)
            # 429 and 5xx are worth one retry; every other 4xx is a real answer.
            if error.code in (429, 500, 502, 503, 504) and attempt == 0:
                time.sleep(2)
                return self._request(method, path, payload, attempt + 1)
            raise ASCError("HTTP %d: %s" % (error.code, detail), error.code)
        except urllib.error.URLError as error:
            raise ASCError("cannot reach App Store Connect: %s" % error.reason)

    def get(self, path: str) -> Dict[str, Any]:
        return self._request("GET", path)

    def post(self, path: str, payload: Dict[str, Any]) -> Dict[str, Any]:
        return self._request("POST", path, payload)

    def patch(self, path: str, payload: Dict[str, Any]) -> Dict[str, Any]:
        return self._request("PATCH", path, payload)

    # ── who is this key ───────────────────────────────────────────────────────

    def team_id(self) -> str:
        """The team this key belongs to, or "" when the team owns no assets yet.

        There is no whoami endpoint, so this is inferred: a signing certificate's
        subject OU *is* the team id, and a registered bundle id's seedId is the
        fallback. Worth the two calls — a key issued for the wrong team answers
        every other question truthfully about the wrong team, which is the one
        failure mode where more data makes you more confident and more wrong."""
        certificates = self.get("/v1/certificates?limit=1").get("data") or []
        if certificates:
            content = certificates[0].get("attributes", {}).get("certificateContent")
            if content:
                team = _certificate_team(base64.b64decode(content))
                if team:
                    return team
        registered = self.get("/v1/bundleIds?limit=1").get("data") or []
        if registered:
            return registered[0].get("attributes", {}).get("seedId") or ""
        return ""

    # ── bundle ids and capabilities ───────────────────────────────────────────

    def bundle_id_record(self, identifier: str) -> Dict[str, Any]:
        """The App ID record plus its enabled capabilities, in one call.

        Capabilities matter here beyond curiosity: this app's whole Apple-facing
        surface fails in ways that look like code bugs when MusicKit is not
        enabled on the App ID, and Family Controls needs a per-bundle-id
        approval with a lead time measured in weeks."""
        payload = self.get("/v1/bundleIds?filter[identifier]=" + identifier
                           + "&include=bundleIdCapabilities&limit=1")
        records = [record for record in (payload.get("data") or [])
                   if record.get("attributes", {}).get("identifier") == identifier]
        if not records:
            return {}
        capabilities = sorted(
            item.get("attributes", {}).get("capabilityType", "")
            for item in (payload.get("included") or [])
            if item.get("type") == "bundleIdCapabilities")
        record = records[0]
        return {
            "id": record.get("id", ""),
            "name": record.get("attributes", {}).get("name", ""),
            "seed_id": record.get("attributes", {}).get("seedId", ""),
            "capabilities": [c for c in capabilities if c],
        }

    def register_bundle_id(self, identifier: str, platform: str = "UNIVERSAL") -> bool:
        """Register the App ID. Returns False when it already existed.

        `platform` matters and is easy to get wrong: an App ID used by both an
        iOS and a Mac target is `UNIVERSAL`, and a `UNIVERSAL` record does not
        match `filter[platform]=IOS`. Registering as IOS when the project builds
        for both is a record that has to be recreated later."""
        if self.bundle_id_record(identifier):
            return False
        name = "".join(c for c in identifier.split(".")[-1].title() if c.isalnum()) or "App"
        self.post("/v1/bundleIds", {"data": {
            "type": "bundleIds",
            "attributes": {"identifier": identifier, "name": name, "platform": platform},
        }})
        return True

    # ── apps and builds ───────────────────────────────────────────────────────

    def apps(self, bundle_id: str) -> List[Dict[str, str]]:
        """App records matching the bundle id EXACTLY.

        `filter[bundleId]` is neither guaranteed-exact nor guaranteed-unique,
        and its ordering is unspecified: since-deleted ghost records for the same
        identifier do come back. Taking data[0] blindly can land on a record that
        holds no builds, which downstream is indistinguishable from "nothing has
        been uploaded yet" — a lie that sends someone hunting a broken upload."""
        payload = self.get("/v1/apps?filter[bundleId]=" + bundle_id + "&fields[apps]=name,bundleId")
        return [{"id": app["id"], "name": app.get("attributes", {}).get("name", "")}
                for app in (payload.get("data") or [])
                if app.get("attributes", {}).get("bundleId") == bundle_id]

    def builds(self, app_id: str, limit: int = 10, train: str = "") -> List[Dict[str, Any]]:
        """Recent builds, newest first.

        Two traps live in this one call.

        `version` on a build is the **build number** (CFBundleVersion), not the
        marketing version — that lives on the related preReleaseVersion, which
        Apple calls the "train". `filter[version]=1.2.0` therefore filters on the
        wrong field and silently returns nothing.

        And `processingState: VALID` does not mean a tester can install it. The
        state that decides that is `buildBetaDetail.internalBuildState`, where
        `READY_FOR_BETA_TESTING` is the green light and `MISSING_EXPORT_COMPLIANCE`
        is a build that processed perfectly and is still undistributable."""
        query = ("/v1/builds?filter[app]=%s&sort=-uploadedDate&limit=%d"
                 "&include=preReleaseVersion,buildBetaDetail"
                 "&fields[builds]=version,processingState,uploadedDate,expired,"
                 "preReleaseVersion,buildBetaDetail" % (app_id, limit))
        if train:
            query += "&filter[preReleaseVersion.version]=" + train
        payload = self.get(query)
        included = {(item.get("type"), item.get("id")): item.get("attributes", {})
                    for item in (payload.get("included") or [])}

        def related(build: Dict[str, Any], name: str, kind: str) -> Dict[str, Any]:
            data = (build.get("relationships", {}).get(name, {}) or {}).get("data") or {}
            return included.get((kind, data.get("id")), {})

        out = []
        for build in (payload.get("data") or []):
            attributes = build.get("attributes", {})
            beta = related(build, "buildBetaDetail", "buildBetaDetails")
            out.append({
                "id": build.get("id", ""),
                "version": attributes.get("version", ""),
                "train": related(build, "preReleaseVersion",
                                 "preReleaseVersions").get("version", ""),
                "state": attributes.get("processingState", ""),
                "beta_state": beta.get("internalBuildState", ""),
                "external_state": beta.get("externalBuildState", ""),
                "uploaded": attributes.get("uploadedDate"),
                "expired": attributes.get("expired", False),
            })
        return out

    def live_app(self, bundle_id: str) -> Dict[str, Any]:
        """The app record that actually holds builds, with them attached.

        When duplicates survive exact matching, let the builds break the tie:
        the record with the most recent upload is the live one and a ghost
        reports nothing and loses."""
        candidates = self.apps(bundle_id)
        if not candidates:
            return {}
        best = dict(candidates[0])
        best["builds"] = []
        for candidate in candidates:
            found = self.builds(candidate["id"])
            if found and (not best["builds"]
                          or _uploaded_key(found[0]) > _uploaded_key(best["builds"][0])):
                best = dict(candidate)
                best["builds"] = found
        return best

    def set_export_compliance(self, build_id: str, uses_encryption: bool = False) -> None:
        """Answer the export-compliance question on an already-uploaded build.

        A build that reaches "Missing Compliance" is not broken, it is waiting
        for a yes/no that the Info.plist key normally answers in advance. This
        is the escape hatch for builds uploaded before that key existed."""
        self.patch("/v1/builds/" + build_id, {"data": {
            "type": "builds", "id": build_id,
            "attributes": {"usesNonExemptEncryption": uses_encryption},
        }})

    # ── TestFlight groups ─────────────────────────────────────────────────────

    def beta_groups(self, app_id: str) -> List[Dict[str, Any]]:
        payload = self.get("/v1/betaGroups?filter[app]=%s&limit=50"
                           "&fields[betaGroups]=name,isInternalGroup" % app_id)
        return [{"id": group["id"],
                 "name": group.get("attributes", {}).get("name", ""),
                 "internal": bool(group.get("attributes", {}).get("isInternalGroup"))}
                for group in (payload.get("data") or [])]

    def create_internal_group(self, app_id: str, name: str) -> Dict[str, Any]:
        """An internal group with automatic distribution turned on.

        Without one, a build finishes processing, reaches "Ready to Test", and
        is visible to nobody — the most demoralising possible outcome of a
        successful release. `hasAccessToAllBuilds` is what makes every later
        build land in the group without anyone touching the console again."""
        payload = self.post("/v1/betaGroups", {"data": {
            "type": "betaGroups",
            "attributes": {"name": name, "isInternalGroup": True,
                           "hasAccessToAllBuilds": True},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
        }})
        record = payload.get("data") or {}
        return {"id": record.get("id", ""), "name": name, "internal": True}


def _certificate_team(der: bytes) -> str:
    with tempfile.NamedTemporaryFile(suffix=".der") as handle:
        handle.write(der)
        handle.flush()
        subject = subprocess.run(
            ["/usr/bin/openssl", "x509", "-inform", "DER", "-in", handle.name,
             "-noout", "-subject"],
            capture_output=True, text=True).stdout
    for part in subject.replace("subject=", "").split(","):
        part = part.strip()
        if part.startswith("OU"):
            return part.split("=", 1)[1].strip()
    return ""


def _uploaded_key(build: Dict[str, Any]) -> str:
    """Sort key for an upload timestamp. ISO-8601 with a Z suffix sorts
    correctly as a string; anything unparseable sorts first rather than raising."""
    value = build.get("uploaded") or ""
    return value if value.endswith("Z") else "0" + value


def client_for(cfg) -> Optional[Client]:
    """A client, or None when the credentials are not complete. Callers treat
    None as "cannot ask Apple", which is a warning, never a failure — the
    pipeline still works off the Xcode login session."""
    creds = cfg.asc_credentials()
    if not (creds["key_id"] and creds["issuer_id"] and creds["key_path"]):
        return None
    return Client(creds["key_path"], creds["key_id"], creds["issuer_id"])
