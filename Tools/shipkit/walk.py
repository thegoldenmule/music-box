"""The interactive driver: one step at a time, with someone at the keyboard.

`next` answers "what now" as data, which is right for a script and useless as a
user interface — it hands you a command and expects you to type it. This runs
the same decision loop and does the typing, asking before each step and staying
on screen until there is nothing left.

There is no second decision engine here. `nextstep.decide` is still the only
thing that chooses; this module only renders it and reacts to a keypress. A
walkthrough that disagreed with `ship next` about what comes next would be two
tools wearing one name.

Manual steps are where a walkthrough earns its keep, because they are the ones a
command cannot perform. The API key is the common case and gets a real
conversation — find the .p8, take the Issuer ID, apply both — rather than three
lines of instructions and a shrug.
"""

from __future__ import annotations

import glob
import os
import subprocess
import sys
import time
from typing import List, Optional, Set

from . import config, nextstep, preflight
from .report import EXIT_OK, EXIT_USAGE, FAIL, OK, SKIP, WARN, Result, fail, ok

RULE = "─" * 72
KEY_PAGE = "https://appstoreconnect.apple.com/access/integrations/api"


def _tty() -> bool:
    return sys.stdin.isatty() and sys.stderr.isatty()


def out(text: str = "") -> None:
    """Everything here is conversation, so it all goes to stderr — same rule as
    the rest of the tool, and it keeps `walk` from being the one command that
    puts prose on stdout."""
    print(text, file=sys.stderr)


def _c(code: str, text: str) -> str:
    return "\033[%sm%s\033[0m" % (code, text) if sys.stderr.isatty() else text


def bold(text: str) -> str:
    return _c("1", text)


def dim(text: str) -> str:
    return _c("2", text)


def ask(prompt: str, default: str = "") -> str:
    """A prompt that treats EOF and Ctrl-C as "stop", not as a crash."""
    try:
        answer = input("\n%s " % prompt).strip()
    except (EOFError, KeyboardInterrupt):
        out("")
        return "q"
    return answer or default


def open_url(url: str) -> None:
    subprocess.run(["open", url], capture_output=True)


# ── the screen ────────────────────────────────────────────────────────────────

def header(facts: preflight.Facts, rows: List) -> None:
    counts = {name: len([r for r in rows if r.status == name])
              for name in (OK, WARN, FAIL, SKIP)}
    out("")
    out(RULE)
    out("  %s  %s  (build %s)" % (bold(facts.cfg.app_name),
                                  facts.marketing_version or "?",
                                  facts.build_number or "?"))
    out("  %s" % dim(facts.bundle_id or "no bundle identifier"))
    out("")
    out("  %s   %s   %s" % (
        _c("32", "%d passing" % counts[OK]),
        _c("33", "%d warning%s" % (counts[WARN], "" if counts[WARN] == 1 else "s")),
        _c("31", "%d failing" % counts[FAIL]) if counts[FAIL] else dim("0 failing")))
    out(RULE)


# Steps that get their own guided conversation below. Printing the row's
# guidance as well would say the same thing twice in two different voices.
GUIDED = {"asc_key"}


def show(action: nextstep.Action) -> None:
    label = {"run": ("36", "NEXT"), "wait": ("33", "WAIT"),
             "manual": ("33", "YOU"), "done": ("32", "DONE")}.get(action.kind, ("0", "NEXT"))
    out("")
    out("  %s  %s" % (_c(label[0], label[1]), bold(action.title)))
    if action.why and action.id not in GUIDED:
        out("")
        for line in action.why.split("\n"):
            out("  " + line)
    for link in action.links:
        out("")
        out("  %s  %s" % (dim("↗ " + link.label), link.url))


# ── running a step ────────────────────────────────────────────────────────────

def run_command(command: str) -> int:
    """Run one of this tool's own commands, in this process.

    Re-entering `main` rather than shelling out keeps the output, the exit codes
    and the rendering identical to running it by hand — which matters, because
    the whole point is that the user could have typed it."""
    from .cli import main
    argv = command.split()
    if argv[:1] == ["Tools/ship"]:
        argv = argv[1:]
    if not argv or argv[0] == "walk":
        return EXIT_USAGE
    out("")
    out(dim("$ Tools/ship %s" % " ".join(argv)))
    return main(argv)


# ── the manual steps worth a conversation ─────────────────────────────────────

def find_keys() -> List[str]:
    """Candidate .p8 files, one entry per key id.

    Newest first is a display order, not a ranking: the most recently downloaded
    key is exactly as likely to be a revoked one. Where an Issuer ID is already
    known, walk_asc_key tests them rather than trusting this order."""
    from . import auth
    out, seen = [], set()
    for path in auth.candidate_keys():
        key_id = auth.key_id_from_filename(path)
        if key_id and key_id not in seen:
            seen.add(key_id)
            out.append(path)
    return out


def walk_asc_key(cfg: config.Config) -> bool:
    """Set up the API key by hand-holding. Returns True if anything changed.

    This is the step everyone stops at, and the instructions version of it
    ("create a key, download it, import it, paste the issuer id") loses people
    between the browser and the terminal."""
    from . import auth

    creds = cfg.asc_credentials()
    if not creds["key_id"] or not os.path.exists(creds["key_path"] or ""):
        candidates = find_keys()
        issuer = creds["issuer_id"]
        if candidates and issuer:
            # With an Issuer ID in hand there is no need to make anyone choose:
            # ask Apple which of these it accepts. This is the step that
            # silently picked a revoked key and then reported an outage.
            out("")
            out(dim("  testing %d key%s…" % (len(candidates), "" if len(candidates) == 1 else "s")))
            for path in candidates:
                key_id = auth.key_id_from_filename(path)
                if auth.works(path, key_id, issuer):
                    result = auth.import_key(cfg, path)
                    out("  %s %s" % ("✓" if result.ok else "✗", result.title))
                    return result.ok
            out("  " + dim("Apple rejected all of them."))
            candidates = []
        if candidates:
            out("")
            out("  Found:")
            for index, path in enumerate(candidates[:5], 1):
                out("    [%d] %s" % (index, path))
            out("    [n] none of these — I need to make one")
            out(dim("    [s] skip this step   [q] quit"))
            answer = ask("Which key? [1]", "1").lower()
            if answer.startswith(("q", "s")):
                return False
            if answer.isdigit() and 1 <= int(answer) <= len(candidates[:5]):
                result = auth.import_key(cfg, candidates[int(answer) - 1])
                out("")
                out("  %s %s" % ("✓" if result.ok else "✗", result.title))
                if not result.ok:
                    out("  " + result.guidance)
                    return False
            else:
                candidates = []
        if not candidates:
            out("")
            out("  Make one: Users and Access → Integrations → ＋")
            out("  " + dim("Role: App Manager. Admin if cloud signing needs to mint a "
                           "certificate — the role cannot be changed later."))
            answer = ask("Open that page? [Y/n/q]", "y").lower()
            if answer.startswith("q"):
                return False
            if answer.startswith("y"):
                open_url(KEY_PAGE)
            answer = ask("Path to the downloaded .p8 (blank to skip):")
            if answer in ("", "q"):
                return False
            result = auth.import_key(cfg, answer)
            out("")
            out("  %s %s" % ("✓" if result.ok else "✗", result.title))
            if not result.ok:
                out("  " + result.guidance)
                return False

    if not cfg.asc_credentials()["issuer_id"]:
        out("")
        out("  " + dim("The Issuer ID is the UUID at the top of that page."))
        answer = ask("Open it? [Y/n]", "y").lower()
        if answer.startswith("q"):
            return False
        if answer.startswith("y"):
            open_url(KEY_PAGE)
        answer = ask("Issuer ID (blank to skip):")
        if answer in ("", "q"):
            return False
        result = auth.set_issuer(cfg, answer)
        out("")
        out("  %s %s" % ("✓" if result.ok else "✗", result.title))
        if not result.ok:
            out("  " + result.guidance)
            return False
    return True


def walk_manual(action: nextstep.Action, cfg: config.Config, skipped: Set[str]) -> str:
    """Handle a step only a person can do. Returns "again", "skip" or "quit"."""
    if action.id == "asc_key":
        if walk_asc_key(cfg):
            return "again"
        skipped.add(action.id)
        return "skip"

    options = "[enter] done, check again"
    if action.links:
        options = "[o] open the link   " + options
    out("")
    out(dim("  " + options + "   [s] skip   [q] quit"))
    answer = ask(">", "").lower()
    if answer.startswith("q"):
        return "quit"
    if answer.startswith("s"):
        skipped.add(action.id)
        return "skip"
    if answer.startswith("o") and action.links:
        open_url(action.links[0].url)
        return walk_manual(action, cfg, skipped)
    return "again"


def walk_wait(action: nextstep.Action, seconds: int = 60) -> str:
    out("")
    answer = ask("Wait %ds and check again? [Y/n/q]" % seconds, "y").lower()
    if answer.startswith(("q", "n")):
        return "quit" if answer.startswith("q") else "skip"
    try:
        for remaining in range(seconds, 0, -5):
            sys.stderr.write("\r  %s  " % dim("checking again in %ds…" % remaining))
            sys.stderr.flush()
            time.sleep(5)
        sys.stderr.write("\r" + " " * 40 + "\r")
    except KeyboardInterrupt:
        out("")
        return "quit"
    return "again"


# ── the loop ──────────────────────────────────────────────────────────────────

def run(cfg: config.Config, as_json: bool = False) -> Result:
    if as_json:
        return fail("`walk` is interactive and has no JSON form",
                    "`Tools/ship next --json` is the same decision as data.")
    if not _tty():
        return fail("`walk` needs a terminal",
                    "There is nobody to ask. `Tools/ship next` is the same decision without "
                    "the prompts.")

    skipped: Set[str] = set()
    while True:
        out("")
        out(dim("  checking…"))
        facts = preflight.gather(cfg, offline=False)
        rows = preflight.rows_for(facts)
        header(facts, rows)

        # A skipped step must not be offered again on the next pass, or the
        # walkthrough becomes an argument.
        for row in rows:
            if row.id in skipped and row.status in (WARN, FAIL):
                row.status = SKIP
        action = nextstep.decide(facts, rows)

        if action.id in skipped and action.kind != "done":
            skipped.discard(action.id)  # it came back around; let it be asked once more

        show(action)

        if action.kind == "done":
            out("")
            out("  " + _c("32", "Nothing left to do."))
            return ok(action.title, data={"next": action.as_dict(), "skipped": sorted(skipped)})

        if action.kind == "wait":
            outcome = walk_wait(action)
        elif action.kind == "manual":
            outcome = walk_manual(action, cfg, skipped)
        else:
            answer = ask("Run it? [Y/n/s(kip)/q]", "y").lower()
            if answer.startswith("q"):
                outcome = "quit"
            elif answer.startswith(("n", "s")):
                skipped.add(action.id)
                outcome = "skip"
            else:
                code = run_command(action.command)
                if code != EXIT_OK:
                    out("")
                    out("  " + _c("31", "That step did not succeed (exit %d)." % code))
                    answer = ask("Keep going anyway? [y/N/q]", "n").lower()
                    if not answer.startswith("y"):
                        return fail("Stopped at: %s" % action.title,
                                    "Nothing was rolled back. `Tools/ship walk` picks up here.",
                                    data={"failed": action.as_dict()})
                outcome = "again"

        if outcome == "quit":
            out("")
            out(dim("  Stopped. `Tools/ship walk` picks up where this left off."))
            return ok("Stopped at: %s" % action.title,
                      data={"next": action.as_dict(), "skipped": sorted(skipped)})
