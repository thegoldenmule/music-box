"""Running external commands.

The Godot original had to run everything detached, because a build that blocked
would freeze the editor. A CLI has no such constraint, so this is deliberately
much smaller: run it, tee the output to a log file and to stderr, hand back the
exit code.

The log file is not a nicety. `xcodebuild` failures are diagnosed by grepping
several hundred lines for the first `error:`, and a caller reading `--json`
never sees the stream at all — so every stage's full output lands somewhere
addressable and the path travels in the result.
"""

from __future__ import annotations

import dataclasses
import os
import shlex
import shutil
import subprocess
import sys
from typing import Dict, List, Optional, Sequence


@dataclasses.dataclass
class Completed:
    code: int
    stdout: str = ""
    stderr: str = ""
    log: str = ""

    @property
    def ok(self) -> bool:
        return self.code == 0

    @property
    def out(self) -> str:
        """Both streams, for matching against failure signatures — xcodebuild
        splits a single diagnosis across the two and a classifier that reads
        only one of them misses half the known failures."""
        return self.stdout + self.stderr

    def tail(self, lines: int = 40) -> str:
        return "\n".join(self.out.rstrip("\n").split("\n")[-lines:])


def quote(argv: Sequence[str]) -> str:
    return " ".join(shlex.quote(str(a)) for a in argv)


def run(argv: Sequence[str], cwd: Optional[str] = None, timeout: Optional[int] = 120,
        env: Optional[Dict[str, str]] = None, stdin: Optional[str] = None) -> Completed:
    """Capture a short command. Never raises — a missing binary is exit 127.

    Probes call this constantly (`xcodebuild -version`, `security find-identity`)
    and every one of them wants to treat "not installed" as an answer rather
    than an exception.
    """
    try:
        proc = subprocess.run(
            [str(a) for a in argv],
            cwd=cwd,
            timeout=timeout,
            env=env,
            input=stdin,
            capture_output=True,
            text=True,
            errors="replace",
        )
    except FileNotFoundError:
        return Completed(127, stderr="%s: command not found" % argv[0])
    except subprocess.TimeoutExpired:
        return Completed(124, stderr="%s: timed out after %ss" % (argv[0], timeout))
    return Completed(proc.returncode, proc.stdout or "", proc.stderr or "")


def run_bytes(argv: Sequence[str], timeout: Optional[int] = 120) -> "tuple[int, bytes]":
    """Like run(), for commands whose stdout is not text (DER, binary plists)."""
    try:
        proc = subprocess.run([str(a) for a in argv], timeout=timeout, capture_output=True)
    except FileNotFoundError:
        return 127, b""
    except subprocess.TimeoutExpired:
        return 124, b""
    return proc.returncode, proc.stdout


def stream(argv: Sequence[str], log_path: str, cwd: Optional[str] = None,
           quiet: bool = False, timeout: Optional[int] = None,
           env: Optional[Dict[str, str]] = None) -> Completed:
    """Run a long command, tee-ing stdout+stderr to `log_path` and to stderr.

    Output goes to stderr rather than stdout so that `--json` remains a clean
    single object on stdout even while a fifteen-minute archive is scrolling
    past.
    """
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    captured: List[str] = []
    header = "$ %s\n" % quote(argv)
    if not quiet:
        sys.stderr.write(header)
        sys.stderr.flush()
    with open(log_path, "w", encoding="utf-8") as log:
        log.write(header)
        try:
            proc = subprocess.Popen(
                [str(a) for a in argv],
                cwd=cwd,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                errors="replace",
                bufsize=1,
            )
        except FileNotFoundError:
            message = "%s: command not found\n" % argv[0]
            log.write(message)
            sys.stderr.write(message)
            return Completed(127, stderr=message, log=log_path)
        assert proc.stdout is not None
        try:
            for line in proc.stdout:
                captured.append(line)
                log.write(line)
                if not quiet:
                    sys.stderr.write(line)
            code = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
            note = "\n[ship] killed after %ss\n" % timeout
            log.write(note)
            captured.append(note)
            code = 124
        except KeyboardInterrupt:
            proc.kill()
            proc.wait()
            note = "\n[ship] interrupted\n"
            log.write(note)
            captured.append(note)
            code = 130
    # stdout and stderr were merged into one pipe on purpose: interleaving is
    # what makes a build log readable, and nothing downstream needs them apart.
    return Completed(code, stdout="".join(captured), log=log_path)


def which(name: str) -> Optional[str]:
    """Absolute path to `name`, or None. (`command -v` is a shell builtin and
    cannot be exec'd, which is a tempting one-liner that always reports 127.)"""
    return shutil.which(name)
