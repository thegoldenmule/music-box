"""The output contract, shared by every subcommand.

Two audiences read this tool and they want opposite things. A person wants a
checklist with colour and the next sentence to act on; a program — CI, or an
LLM driving the release — wants one parseable object and an exit code it can
branch on. So every command produces a `Result`, and the only choice made at
the edge is whether to render it as prose or as JSON.

The rule that keeps `--json` usable: **prose goes to stderr, the object goes to
stdout.** `ship doctor --json | jq` works while the human-readable progress is
still visible in the terminal.

Exit codes are part of the contract:

    0  ok
    1  failed — something the tool tried did not work
    2  usage error
    3  blocked on a human — a step no tool can perform (create the app record,
       accept an agreement, wait for Apple). A caller that retries on 1 must
       NOT retry on 3.
"""

from __future__ import annotations

import dataclasses
import json
import os
import sys
from typing import Any, Dict, List, Optional

EXIT_OK = 0
EXIT_FAIL = 1
EXIT_USAGE = 2
EXIT_BLOCKED = 3

# Status values a checklist row can carry. `busy` exists in the Godot original
# because its checks were async; here everything blocks, so a row is only ever
# in a settled state. `skip` means "not checked", which is not the same as ok
# and must never be rendered as one.
OK, WARN, FAIL, SKIP = "ok", "warn", "fail", "skip"


def _tty() -> bool:
    return sys.stderr.isatty() and os.environ.get("NO_COLOR") is None


def _c(code: str, text: str) -> str:
    return "\033[%sm%s\033[0m" % (code, text) if _tty() else text


def dim(text: str) -> str:
    return _c("2", text)


def bold(text: str) -> str:
    return _c("1", text)


STATUS_MARK = {
    OK: ("32", "✓"),
    WARN: ("33", "!"),
    FAIL: ("31", "✗"),
    SKIP: ("2", "–"),
}


@dataclasses.dataclass
class Link:
    """Somewhere the user has to go. A URL, or a local path to `open`."""

    label: str
    url: str

    def as_dict(self) -> Dict[str, str]:
        return {"label": self.label, "url": self.url}


@dataclasses.dataclass
class Row:
    """One line of the preflight checklist.

    `fix` is the id to pass to `ship fix` — set only when this tool can actually
    repair the row. A row that needs a human says so in `guidance` and leaves
    `fix` empty; conflating the two is how a checklist starts lying.
    """

    id: str
    label: str
    status: str
    detail: str = ""
    guidance: str = ""
    links: List[Link] = dataclasses.field(default_factory=list)
    fix: str = ""
    # True when only a human can clear this row (create the app record, wait for
    # Apple). Drives the exit-code-3 decision and what `ship next` will attempt.
    manual: bool = False

    def as_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "label": self.label,
            "status": self.status,
            "detail": self.detail,
            "guidance": self.guidance,
            "links": [l.as_dict() for l in self.links],
            "fix": self.fix,
            "manual": self.manual,
        }

    def render(self) -> str:
        color, mark = STATUS_MARK.get(self.status, ("0", "?"))
        head = "%s %-34s %s" % (_c(color, mark), self.label, dim(self.detail))
        if not self.guidance:
            return head
        body = "\n".join("      " + line for line in self.guidance.split("\n"))
        out = head + "\n" + body
        for link in self.links:
            out += "\n      " + dim("↗ %s  %s" % (link.label, link.url))
        if self.fix:
            out += "\n      " + bold("Tools/ship fix %s" % self.fix)
        return out


@dataclasses.dataclass
class Result:
    """What every command returns.

    `data` is the command-specific payload and is the only part whose shape
    varies. `title` and `guidance` are always present so a caller that
    understands nothing else still has something to show a person.
    """

    ok: bool
    title: str = ""
    guidance: str = ""
    links: List[Link] = dataclasses.field(default_factory=list)
    data: Dict[str, Any] = dataclasses.field(default_factory=dict)
    blocked: bool = False
    # The caller asked for something that does not exist. Distinct from a
    # failure: nothing was attempted, and the invocation is what needs changing.
    usage: bool = False

    @property
    def exit_code(self) -> int:
        if self.ok:
            return EXIT_OK
        if self.usage:
            return EXIT_USAGE
        return EXIT_BLOCKED if self.blocked else EXIT_FAIL

    def as_dict(self, command: str = "") -> Dict[str, Any]:
        out: Dict[str, Any] = {
            "ok": self.ok,
            "blocked": self.blocked,
            "usage": self.usage,
            "title": self.title,
            "guidance": self.guidance,
            "links": [l.as_dict() for l in self.links],
            "data": self.data,
        }
        if command:
            out["command"] = command
        return out


def ok(title: str = "", guidance: str = "", data: Optional[Dict[str, Any]] = None,
       links: Optional[List[Link]] = None) -> Result:
    return Result(True, title, guidance, links or [], data or {})


def fail(title: str, guidance: str = "", data: Optional[Dict[str, Any]] = None,
         links: Optional[List[Link]] = None, blocked: bool = False) -> Result:
    return Result(False, title, guidance, links or [], data or {}, blocked)


def blocked(title: str, guidance: str = "", data: Optional[Dict[str, Any]] = None,
            links: Optional[List[Link]] = None) -> Result:
    """A human has to do something. Distinct from failure: retrying won't help."""
    return fail(title, guidance, data, links, blocked=True)


def usage(title: str, guidance: str = "", data: Optional[Dict[str, Any]] = None) -> Result:
    """The invocation named something that does not exist. Nothing was tried."""
    result = fail(title, guidance, data)
    result.usage = True
    return result


def say(text: str = "") -> None:
    """Human-facing progress. Always stderr, so `--json` stays pipeable."""
    print(text, file=sys.stderr)


def emit(result: Result, as_json: bool, command: str = "") -> int:
    """Render and return the exit code."""
    if as_json:
        json.dump(result.as_dict(command), sys.stdout, indent=2)
        sys.stdout.write("\n")
        return result.exit_code
    if result.title:
        color = "32" if result.ok else ("33" if result.blocked else "31")
        mark = "✓" if result.ok else ("→" if result.blocked else "✗")
        say("")
        say("%s %s" % (_c(color, mark), bold(result.title)))
    if result.guidance:
        say(result.guidance)
    for link in result.links:
        say(dim("↗ %s  %s" % (link.label, link.url)))
    return result.exit_code
