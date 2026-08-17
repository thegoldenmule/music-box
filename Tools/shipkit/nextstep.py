"""One action at a time.

`doctor` answers "what is the state of everything", which is the right question
for a person reading a terminal and the wrong one for anything driving this in a
loop. Fifteen rows with four warnings is not an instruction.

`next` answers "what should happen now" with exactly one thing, and says whether
this tool can do it or a human has to. That turns the release into a loop
something else can run:

    while :; do
      step=$(Tools/ship next --json)
      case $(jq -r .data.next.kind <<<"$step") in
        done)   break ;;
        manual) echo "$step" | jq -r .guidance; break ;;
        *)      eval "$(jq -r .data.next.command <<<"$step")" || break ;;
      esac
    done

The ordering below is the whole design. It is not "most severe first" — it is
the order in which doing one thing stops being wasted effort. There is no point
computing a build number before the app record exists, and no point uploading
from a tree whose commit will not describe what shipped.
"""

from __future__ import annotations

import dataclasses
from typing import Any, Dict, List, Optional

from . import config, preflight, xcode
from .report import FAIL, OK, WARN, Link, Result, blocked, ok, say

# Warnings worth clearing before a first upload even though nothing blocks on
# them. Each one costs more later than now: an undeclared compliance answer
# makes every build undistributable until answered by hand, and a missing
# internal group means a successful release reaches nobody.
RECOMMENDED = ("encryption", "beta_group")


@dataclasses.dataclass
class Action:
    id: str
    title: str
    why: str
    # "run" — this tool can do it; "manual" — a human must; "done" — nothing left.
    kind: str = "run"
    command: str = ""
    links: List[Link] = dataclasses.field(default_factory=list)

    def as_dict(self) -> Dict[str, Any]:
        return {"id": self.id, "title": self.title, "why": self.why, "kind": self.kind,
                "command": self.command, "links": [l.as_dict() for l in self.links]}


def _from_row(row) -> Action:
    return Action(
        id=row.id,
        title=row.label + (": " + row.detail if row.detail else ""),
        why=row.guidance,
        kind="run" if row.fix else "manual",
        command="Tools/ship fix %s" % row.fix if row.fix else "",
        links=row.links,
    )


def decide(facts: preflight.Facts, rows: List) -> Action:
    by_id = {row.id: row for row in rows}

    # 1. Anything genuinely broken, repairable ones first — a fix that can be
    #    applied now may also clear rows below it.
    failures = [row for row in rows if row.status == FAIL]
    for row in sorted(failures, key=lambda r: 0 if r.fix else 1):
        return _from_row(row)

    # 2. Credentials. Not a failure — the pipeline runs on an Xcode session —
    #    but without them nothing can be checked before a build or read after
    #    one, so every later step is guesswork.
    key_row = by_id.get("asc_key")
    if key_row is not None and key_row.status == WARN:
        action = _from_row(key_row)
        # It is genuinely optional, so this must not be a dead end. A loop that
        # stops here has to leave the human a way forward that is not "give up".
        action.why += ("\n\nIf you would rather not: `Tools/ship release` works without a key — "
                       "xcodebuild rides your Xcode login session. What you lose is every check "
                       "that happens before the build and every answer after it, including "
                       "`Tools/ship status`.")
        return action

    # 3. The cheap things that are painful later.
    for row_id in RECOMMENDED:
        row = by_id.get(row_id)
        if row is not None and row.status == WARN and row.fix:
            return _from_row(row)

    # 4. Is there already a build in flight? Uploading a second one while the
    #    first is processing is how two builds end up racing for the same
    #    number.
    builds = (facts.app or {}).get("builds") or []
    if builds:
        latest = builds[0]
        local = facts.build_number
        if latest.get("version") == local and latest.get("train") == facts.marketing_version:
            beta = latest.get("beta_state", "")
            if latest.get("state") == "PROCESSING" or beta == "PROCESSING":
                return Action("wait", "Build %s is processing" % latest["version"],
                              "Apple is scanning the build already uploaded from this project. "
                              "Ask again in a few minutes.",
                              kind="run", command="Tools/ship status")
            if beta == "MISSING_EXPORT_COMPLIANCE":
                return Action("compliance",
                              "Build %s is waiting on export compliance" % latest["version"],
                              "It uploaded and processed and no tester can install it. Declaring "
                              "the key in the Info.plist stops it recurring; this build still "
                              "needs the answer given once in the console.",
                              kind="manual",
                              links=[Link("Open My Apps",
                                          "https://appstoreconnect.apple.com/apps")])
            if beta in ("READY_FOR_BETA_TESTING", "IN_BETA_TESTING"):
                return Action("done", "Build %s is ready to test" % latest["version"],
                              "Nothing left for this tool to do. Open the TestFlight app on the "
                              "phone, signed in with the same Apple ID.",
                              kind="done",
                              links=[Link("TestFlight for iPhone",
                                          "https://apps.apple.com/app/testflight/id899247664")])

    # 5. The tree. Only when a release is actually next — a dirty tree does not
    #    matter until something is about to be uploaded from it.
    git_row = by_id.get("git")
    if git_row is not None and git_row.status == WARN:
        return Action("commit", "Commit the working tree",
                      "A build uploaded from a dirty tree cannot be reproduced: the commit "
                      "recorded against it is not the code that shipped.\n%s" % git_row.detail,
                      kind="manual")

    return Action("release", "Ship it",
                  "Everything that can be checked in advance passes. This runs the package "
                  "tests, bumps the build number, archives, reads the result back out of the "
                  "artifact, and uploads.",
                  kind="run", command="Tools/ship release")


def run(cfg: config.Config) -> Result:
    facts = preflight.gather(cfg, offline=False)
    rows = preflight.rows_for(facts)
    action = decide(facts, rows)
    data = {
        "next": action.as_dict(),
        "blocking": [row.id for row in rows if row.status == FAIL],
        "warnings": [row.id for row in rows if row.status == WARN],
    }
    # The command goes into the guidance rather than being printed separately,
    # so `--json` and the terminal carry the same one sentence and there is no
    # second rendering path to keep in step.
    guidance = action.why
    if action.command:
        guidance = (guidance + "\n\n" if guidance else "") + "  $ " + action.command
    if action.kind == "manual":
        return blocked(action.title, guidance, data=data, links=action.links)
    return ok(action.title, guidance, data=data, links=action.links)
