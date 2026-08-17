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
from typing import Any, Dict, List, Optional

# Beside the package rather than at a hardcoded repo path, so the whole of
# `Tools/` can be copied into another project and still find its own settings.
CONFIG_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                           "ship.config.json")
ENV_BASENAME = ".env"

# Environment variables win over the .env file, so CI can inject credentials
# without writing anything to disk.
ASC_VARS = ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH")


def repo_root(start: Optional[str] = None) -> str:
    """Nearest ancestor holding a .git. Falls back to the start directory."""
    path = os.path.abspath(start or os.getcwd())
    while True:
        if os.path.isdir(os.path.join(path, ".git")):
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
        """Persist credentials, then make sure the file they went into is
        ignored — writing a secret into a tracked file only relocates the leak."""
        text = ""
        if os.path.exists(self.env_path):
            with open(self.env_path, encoding="utf-8") as handle:
                text = handle.read()
        with open(self.env_path, "w", encoding="utf-8") as handle:
            handle.write(upsert_env_text(text, values))
        os.chmod(self.env_path, 0o600)
        self.ensure_env_gitignored()
        return self.env_path

    def ensure_env_gitignored(self) -> bool:
        ignore = os.path.join(self.root, ".gitignore")
        text = ""
        if os.path.exists(ignore):
            with open(ignore, encoding="utf-8") as handle:
                text = handle.read()
            if gitignore_covers_env(text):
                return True
        elif not os.path.isdir(os.path.join(self.root, ".git")):
            return False
        if text and not text.endswith("\n"):
            text += "\n"
        with open(ignore, "w", encoding="utf-8") as handle:
            handle.write(text + "\n# App Store Connect API credentials (Tools/ship auth)\n.env\n")
        return True

    # ── persistence ───────────────────────────────────────────────────────────

    def save(self) -> str:
        os.makedirs(os.path.dirname(self.config_path), exist_ok=True)
        payload = {
            "scheme": self.scheme,
            "configuration": self.configuration,
            "beta_group": self.beta_group,
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
    known = {"xcodeproj", "scheme", "configuration", "beta_group", "build_dir"}
    return Config(
        root=root,
        xcodeproj=project,
        scheme=scheme or stored.get("scheme") or name,
        configuration=configuration or stored.get("configuration") or "Release",
        build_dir=stored.get("build_dir") or (os.path.join(os.path.dirname(project), "build", "ship")
                                              if project else os.path.join(root, "build", "ship")),
        beta_group=stored.get("beta_group") or "Internal",
        extra={k: v for k, v in stored.items() if k not in known},
    )
