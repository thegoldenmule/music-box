"""Where the tool finds the project, and where the two kinds of state live.

Almost nothing needs configuring. The bundle identifier, the team, the version
and the deployment target are all *already* in the Xcode project, and a config
file that restates them is a second source of truth that will drift. So this
module's job is mostly discovery: find the repo, find the one `.xcodeproj`, and
let `xcodebuild` answer the rest.

What genuinely cannot be derived splits by whether it is safe to commit:

    shared settings   Tools/ship.config.json   committed    scheme, group name
    credentials       <repo>/.env              gitignored   ASC_KEY_ID, …

The `.p8` itself is never copied into the repo — `auth import` puts it in
`~/private_keys/` and stores a home-relative path, so the same `.env` resolves
on another machine.
"""

from __future__ import annotations

import dataclasses
import json
import os
import tempfile
from typing import Any, Dict, List, Optional

from . import proc


class SecretWriteRefused(Exception):
    """Raised rather than writing a credential somewhere git could commit it.

    An exception and not a False return, because the one caller who forgets to
    check a boolean is the reason the secret ends up in the repository."""

# Beside the package rather than at a hardcoded repo path, so the whole of
# `Tools/` can be copied into another project and still find its own settings.
CONFIG_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                           "ship.config.json")
ENV_BASENAME = ".env"

# Environment variables win over the .env file, so CI can inject credentials
# without writing anything to disk.
ASC_VARS = ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH")


def repo_root(start: Optional[str] = None) -> str:
    """Nearest ancestor holding a `.git`. Falls back to the start directory.

    `exists`, not `isdir`: inside a git worktree or a submodule, `.git` is a
    *file* pointing at the real git directory. Testing for a directory walks
    straight past it and returns some unrelated outer repository — which would
    then be where a credential got written."""
    path = os.path.abspath(start or os.getcwd())
    while True:
        if os.path.exists(os.path.join(path, ".git")):
            return path
        parent = os.path.dirname(path)
        if parent == path:
            return os.path.abspath(start or os.getcwd())
        path = parent


def find_xcodeproj(root: str) -> Optional[str]:
    """The app project. `Apps/` first, because that is where this repo puts the
    only thing with an Info.plist — everything else is a SwiftPM package with no
    project file at all. A DerivedData copy would be a false positive, so
    anything under a build directory is skipped."""
    candidates: List[str] = []
    for base in (os.path.join(root, "Apps"), root):
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, _ in os.walk(base):
            dirnames[:] = [d for d in dirnames
                           if d not in (".git", "build", "DerivedData", ".build")
                           and not d.endswith(".xcodeproj")]
            for name in sorted(os.listdir(dirpath)):
                if name.endswith(".xcodeproj"):
                    candidates.append(os.path.join(dirpath, name))
        if candidates:
            break
    return sorted(candidates)[0] if candidates else None


def parse_env(text: str) -> Dict[str, str]:
    out: Dict[str, str] = {}
    for line in text.split("\n"):
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        key, _, value = s.partition("=")
        key = key.strip()
        if key.startswith("export "):
            key = key[len("export "):].strip()
        out[key] = value.strip().strip('"').strip("'")
    return out


def upsert_env_text(text: str, values: Dict[str, str]) -> str:
    """Rewrite existing keys in place, append the rest. Comments, blank lines and
    unrelated keys survive — a release tool must never be the reason someone's
    unrelated secret vanished. Pure, so it is testable without touching disk."""
    remaining = dict(values)
    out: List[str] = []
    for line in text.split("\n"):
        s = line.strip()
        handled = False
        if s and not s.startswith("#") and "=" in s:
            key = s.split("=", 1)[0].strip()
            prefix = ""
            if key.startswith("export "):
                prefix, key = "export ", key[len("export "):].strip()
            if key in remaining:
                out.append("%s%s=%s" % (prefix, key, remaining.pop(key)))
                handled = True
        if not handled:
            out.append(line)
    joined = "\n".join(out)
    if remaining:
        if joined and not joined.endswith("\n"):
            joined += "\n"
        for key, value in remaining.items():
            joined += "%s=%s\n" % (key, value)
    return joined


def tildify(path: str) -> str:
    home = os.path.expanduser("~")
    return "~" + path[len(home):] if path.startswith(home + "/") else path


def gitignore_covers_env(text: str) -> bool:
    return any(line.strip() in (".env", "/.env", "*.env", ".env*") for line in text.split("\n"))


@dataclasses.dataclass
class Config:
    root: str
    xcodeproj: str
    scheme: str
    configuration: str = "Release"
    # Where archives, exported .ipas and stage logs go. Gitignored by the
    # repo's existing `build/` rule.
    build_dir: str = ""
    # The internal TestFlight group a finished build should reach. Naming it
    # lets `doctor` say "the build will land nowhere" before the upload rather
    # than after.
    beta_group: str = "Internal"
    # An explicit "I am not going to configure an API key". Without it `next`
    # would return the same manual step forever on a machine that will never
    # have one, and could never reach a terminal state.
    skip_asc_key: bool = False
    extra: Dict[str, Any] = dataclasses.field(default_factory=dict)

    @property
    def config_path(self) -> str:
        return CONFIG_PATH

    @property
    def env_path(self) -> str:
        return os.path.join(self.root, ENV_BASENAME)

    @property
    def project_dir(self) -> str:
        return os.path.dirname(self.xcodeproj)

    @property
    def app_name(self) -> str:
        return os.path.basename(self.xcodeproj)[: -len(".xcodeproj")]

    @property
    def logs_dir(self) -> str:
        return os.path.join(self.build_dir, "logs")

    # ── credentials ───────────────────────────────────────────────────────────

    def asc_credentials(self) -> Dict[str, str]:
        """{key_id, issuer_id, key_path}; empty strings mean unset.

        Process environment first so CI can inject without a file, then the
        repo `.env`. The key path is stored home-relative and expanded here."""
        env_file: Dict[str, str] = {}
        if os.path.exists(self.env_path):
            with open(self.env_path, encoding="utf-8") as handle:
                env_file = parse_env(handle.read())
        values = {name: (os.environ.get(name) or env_file.get(name) or "").strip()
                  for name in ASC_VARS}
        path = values["ASC_KEY_PATH"]
        return {
            "key_id": values["ASC_KEY_ID"],
            "issuer_id": values["ASC_ISSUER_ID"],
            "key_path": os.path.expanduser(path) if path else "",
        }

    def has_asc_key(self) -> bool:
        creds = self.asc_credentials()
        return all(creds.values()) and os.path.exists(creds["key_path"])

    def write_env(self, values: Dict[str, str]) -> str:
        """Persist credentials. Refuses rather than leaking.

        Order is the whole point. The ignore rule goes in *before* the secret
        touches the disk, and git is asked whether it actually took — writing
        first and checking after means the one run where the check fails is the
        run that already wrote the credential into a committable file.

        The write itself is atomic: a temp file in the same directory, created
        0600 so it is never briefly world-readable, then `os.replace`. Opening
        the real path with "w" truncates it before a single byte is written, so
        a crash mid-write would destroy an existing .env holding unrelated
        secrets — which is exactly what this promises not to do."""
        self.ensure_env_gitignored()
        protected, reason = self.env_protected()
        if not protected:
            raise SecretWriteRefused(
                "Refusing to write credentials to %s: %s" % (self.env_path, reason))

        text = ""
        if os.path.exists(self.env_path):
            with open(self.env_path, encoding="utf-8") as handle:
                text = handle.read()
        updated = upsert_env_text(text, values)

        directory = os.path.dirname(self.env_path) or "."
        handle_fd, temp = tempfile.mkstemp(dir=directory, prefix=".env.", suffix=".tmp")
        try:
            os.fchmod(handle_fd, 0o600)
            with os.fdopen(handle_fd, "w", encoding="utf-8") as handle:
                handle.write(updated)
            os.replace(temp, self.env_path)
        except BaseException:
            if os.path.exists(temp):
                os.unlink(temp)
            raise
        return self.env_path

    def env_protected(self) -> "tuple[bool, str]":
        """(is the .env safe to write, why not).

        Ask git rather than pattern-matching the .gitignore: git is the only
        authority on its own rules, and it is the thing that will or will not
        commit the file. Two answers matter and only one of them is obvious —
        a file git already *tracks* is never ignored no matter what rule exists,
        so adding one would be a fix that changes nothing."""
        if not os.path.exists(os.path.join(self.root, ".git")):
            return True, ""  # not a repo: nothing here can be committed
        tracked = proc.run(["git", "-C", self.root, "ls-files", "--error-unmatch",
                            self.env_path], timeout=30)
        if tracked.ok:
            return False, ("git already tracks it, so no ignore rule can help. Run "
                           "`git rm --cached %s` first, and treat anything already committed "
                           "there as disclosed." % os.path.relpath(self.env_path, self.root))
        ignored = proc.run(["git", "-C", self.root, "check-ignore", "-q", self.env_path],
                           timeout=30)
        if ignored.ok:
            return True, ""
        return False, ("git does not ignore it, and the ignore rule could not be added. Add "
                       "`.env` to %s by hand." % os.path.join(self.root, ".gitignore"))

    def ensure_env_gitignored(self) -> bool:
        ignore = os.path.join(self.root, ".gitignore")
        text = ""
        if os.path.exists(ignore):
            with open(ignore, encoding="utf-8") as handle:
                text = handle.read()
            if gitignore_covers_env(text):
                return True
        elif not os.path.exists(os.path.join(self.root, ".git")):
            return False
        if text and not text.endswith("\n"):
            text += "\n"
        try:
            with open(ignore, "w", encoding="utf-8") as handle:
                handle.write(text
                             + "\n# App Store Connect API credentials (Tools/ship auth)\n.env\n")
        except OSError:
            return False
        return True

    # ── persistence ───────────────────────────────────────────────────────────

    def save(self) -> str:
        os.makedirs(os.path.dirname(self.config_path), exist_ok=True)
        payload = {
            "scheme": self.scheme,
            "configuration": self.configuration,
            "beta_group": self.beta_group,
            "skip_asc_key": self.skip_asc_key,
        }
        payload.update(self.extra)
        with open(self.config_path, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(payload, indent=2) + "\n")
        return self.config_path


def load(start: Optional[str] = None, xcodeproj: Optional[str] = None,
         scheme: Optional[str] = None, configuration: Optional[str] = None) -> Config:
    """Discover the project and merge in the config file, then flag overrides.

    Precedence, lowest first: discovered → config file → command-line flag."""
    root = repo_root(start)
    stored: Dict[str, Any] = {}
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, encoding="utf-8") as handle:
                loaded = json.load(handle)
            if isinstance(loaded, dict):
                stored = loaded
        except (ValueError, OSError):
            stored = {}

    project = xcodeproj or stored.get("xcodeproj") or find_xcodeproj(root) or ""
    if project and not os.path.isabs(project):
        project = os.path.join(root, project)
    name = os.path.basename(project)[: -len(".xcodeproj")] if project else ""
    known = {"xcodeproj", "scheme", "configuration", "beta_group", "build_dir", "skip_asc_key"}
    return Config(
        root=root,
        xcodeproj=project,
        scheme=scheme or stored.get("scheme") or name,
        configuration=configuration or stored.get("configuration") or "Release",
        build_dir=stored.get("build_dir") or (os.path.join(os.path.dirname(project), "build", "ship")
                                              if project else os.path.join(root, "build", "ship")),
        beta_group=stored.get("beta_group") or "Internal",
        skip_asc_key=bool(stored.get("skip_asc_key", False)),
        extra={k: v for k, v in stored.items() if k not in known},
    )
