#!/usr/bin/env python3
"""Request and watch one GitHub @codex review round."""

from __future__ import annotations

import argparse
import datetime as _dt
import errno
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any


EXIT_CLEAN = 0
EXIT_PENDING = 1
EXIT_FINDINGS = 20
EXIT_FAILED = 30
EXIT_STALE_HEAD = 40
EXIT_USAGE = 64
EXIT_API = 70

# gh's own exit statuses that waiting cannot fix: 2 usage, 4 not authenticated,
# 127 gh not on PATH. Everything else (notably 1, which covers a 502 and a
# secondary rate limit) is worth another interval.
HARD_API_CODES = frozenset({2, 4, 127})
CODEX_ACTOR = "chatgpt-codex-connector[bot]"


class CodexReviewError(Exception):
    def __init__(self, message: str, code: int = EXIT_USAGE) -> None:
        super().__init__(message)
        self.code = code


class GitHubError(Exception):
    def __init__(self, message: str, code: int) -> None:
        super().__init__(message)
        self.code = code


class WatchDeadlineExpired(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        self.print_usage(sys.stderr)
        raise CodexReviewError(message)


@dataclass
class WatchConfig:
    pr: str
    repo: str
    sha: str
    baseline_review_id: int = 0
    baseline_issue_comment_id: int = 0
    baseline_failure_comment_id: int = 0
    baseline_pull_comment_id: int = 0
    requested_at: str = ""
    request_comment_id: str = ""
    interval: int = 60
    timeout: int = 3600
    once: bool = False
    actor: str = CODEX_ACTOR


def die(message: str, code: int = EXIT_USAGE) -> None:
    raise CodexReviewError(message, code)


def run(args: list[str], timeout: float | None = None) -> subprocess.CompletedProcess[str]:
    try:
        # encoding SPELLED OUT. `text=True` alone decodes with the platform's preferred codec,
        # which on Windows is the ANSI codepage — and GitHub's JSON is UTF-8, so one em-dash in
        # a PR body raised UnicodeDecodeError inside subprocess, left `stdout` as None, and the
        # failure surfaced far away as "object of type 'NoneType' has no len()" in the JSON
        # parser. errors='replace' so a stray byte degrades one character instead of losing a
        # whole review. No effect on POSIX, where UTF-8 is already the answer.
        return subprocess.run(args, text=True, encoding="utf-8", errors="replace",
            capture_output=True, check=False, timeout=timeout)
    except FileNotFoundError:
        return subprocess.CompletedProcess(args, 127, "", f"command not found: {args[0]}")
    except subprocess.TimeoutExpired as exc:
        raise WatchDeadlineExpired() from exc


def run_checked(args: list[str], label: str, timeout: float | None = None) -> str:
    proc = run(args, timeout=timeout)
    if proc.returncode != 0:
        stderr = proc.stderr.strip()
        if stderr:
            print(stderr, file=sys.stderr)
        raise GitHubError(f"codex-review: {label} failed ({proc.returncode})", proc.returncode)
    return proc.stdout


def parse_json_documents(text: str) -> list[Any]:
    decoder = json.JSONDecoder()
    docs: list[Any] = []
    idx = 0
    while True:
        while idx < len(text) and text[idx].isspace():
            idx += 1
        if idx >= len(text):
            return docs
        value, idx = decoder.raw_decode(text, idx)
        docs.append(value)


def remaining_timeout(deadline: float | None) -> float | None:
    if deadline is None:
        return None
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise WatchDeadlineExpired()
    return remaining


def gh_json(repo: str, path: str, paginate: bool = False, timeout: float | None = None) -> Any:
    args = ["gh", "api"]
    if paginate:
        args.append("--paginate")
    endpoint = f"repos/{repo}/{path}"
    args.append(endpoint)
    stdout = run_checked(args, f"gh api {endpoint}", timeout=timeout)
    try:
        docs = parse_json_documents(stdout)
    except json.JSONDecodeError as exc:
        raise GitHubError(f"codex-review: gh api returned invalid JSON for {endpoint}: {exc}", EXIT_API) from exc
    if paginate:
        items: list[Any] = []
        for doc in docs:
            if isinstance(doc, list):
                items.extend(doc)
            elif doc:
                items.append(doc)
        return items
    if not docs:
        return None
    return docs[-1]


def gh_items(repo: str, path: str, timeout: float | None = None) -> list[dict[str, Any]]:
    return [item for item in gh_json(repo, path, paginate=True, timeout=timeout) if isinstance(item, dict)]


def gh_object(repo: str, path: str, timeout: float | None = None) -> dict[str, Any]:
    obj = gh_json(repo, path, timeout=timeout)
    if not isinstance(obj, dict):
        raise GitHubError(f"codex-review: expected object from repos/{repo}/{path}", EXIT_API)
    return obj


def gh_user_login() -> str:
    stdout = run_checked(["gh", "api", "user"], "gh api user")
    try:
        docs = parse_json_documents(stdout)
    except json.JSONDecodeError as exc:
        raise GitHubError(f"codex-review: gh api returned invalid JSON for user: {exc}", EXIT_API) from exc
    user = docs[-1] if docs else {}
    if not isinstance(user, dict) or not user.get("login"):
        raise GitHubError("codex-review: could not read authenticated gh user", EXIT_API)
    return str(user["login"])


def gh_pr_head(repo: str, pr: str) -> str:
    proc = run(["gh", "pr", "view", pr, "--repo", repo, "--json", "headRefOid", "--jq", ".headRefOid"])
    if proc.returncode != 0:
        if proc.stderr.strip():
            print(proc.stderr.strip(), file=sys.stderr)
        raise GitHubError(f"codex-review: gh pr view failed ({proc.returncode})", proc.returncode)
    sha = proc.stdout.strip()
    if not sha:
        die("could not read PR head SHA")
    return sha


def gh_pr_comment(repo: str, pr: str, body_text: str) -> str:
    proc = run(["gh", "pr", "comment", pr, "--repo", repo, "--body", body_text])
    if proc.returncode != 0:
        if proc.stderr.strip():
            print(proc.stderr.strip(), file=sys.stderr)
        raise GitHubError(f"codex-review: gh pr comment failed ({proc.returncode})", proc.returncode)
    return proc.stdout.strip()


def git_stdout(args: list[str]) -> str:
    proc = run(["git", *args])
    if proc.returncode != 0:
        die(proc.stderr.strip() or f"git {' '.join(args)} failed")
    return proc.stdout.strip()


def require_clean_worktree() -> None:
    status = git_stdout(["status", "--porcelain", "--untracked-files=normal"])
    if status:
        die("worktree has uncommitted or untracked files; commit/stash them before requesting review")


def repo_slug() -> str:
    proc = run(["git", "config", "--get", "remote.origin.url"])
    url = proc.stdout.strip() if proc.returncode == 0 else ""
    for prefix in ("git@github.com:", "ssh://git@github.com/", "https://github.com/"):
        if url.startswith(prefix):
            return url[len(prefix):].removesuffix(".git")
    die("could not infer GitHub repo from origin")
    raise AssertionError("unreachable")


def git_path(args: list[str]) -> Path:
    path = Path(git_stdout(args))
    if path.is_absolute():
        return path
    return Path.cwd() / path


def lock_parent() -> Path:
    override = os.environ.get("CODEX_REVIEW_LOCK_DIR")
    if override:
        return Path(override)
    return git_path(["rev-parse", "--git-common-dir"])


def stale_lock_seconds() -> int:
    value = os.environ.get("CODEX_REVIEW_LOCK_STALE_SECONDS", "900")
    try:
        seconds = int(value)
    except ValueError:
        die("CODEX_REVIEW_LOCK_STALE_SECONDS must be an integer")
    if seconds < 0:
        die("CODEX_REVIEW_LOCK_STALE_SECONDS must be non-negative")
    return seconds


def lock_timeout_seconds(default: int) -> int:
    value = os.environ.get("CODEX_REVIEW_LOCK_TIMEOUT_SECONDS", str(default))
    try:
        seconds = int(value)
    except ValueError:
        die("CODEX_REVIEW_LOCK_TIMEOUT_SECONDS must be an integer")
    if seconds <= 0:
        die("CODEX_REVIEW_LOCK_TIMEOUT_SECONDS must be positive")
    return seconds


def lock_owner(lock_dir: Path) -> dict[str, str]:
    owner = lock_dir / "owner"
    values: dict[str, str] = {}
    try:
        for raw in owner.read_text().splitlines():
            key, value = raw.split("=", 1)
            values[key] = value
    except (FileNotFoundError, OSError, ValueError):
        pass
    return values


def lock_created_at(lock_dir: Path, owner: dict[str, str]) -> float:
    try:
        return float(owner["created_at"])
    except (KeyError, ValueError):
        pass
    try:
        return lock_dir.stat().st_mtime
    except FileNotFoundError:
        return time.time()


def pid_is_alive(pid_text: str) -> bool:
    try:
        pid = int(pid_text)
    except ValueError:
        return False
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def reclaim_stale_lock(lock_dir: Path, stale_after: int) -> bool:
    owner = lock_owner(lock_dir)
    if time.time() - lock_created_at(lock_dir, owner) < stale_after:
        return False
    if owner.get("pid") and pid_is_alive(owner["pid"]):
        return False
    try:
        (lock_dir / "owner").unlink()
    except FileNotFoundError:
        pass
    try:
        lock_dir.rmdir()
    except (FileNotFoundError, OSError):
        return False
    return True


def lock_is_owned_by(lock_dir: Path, token: str) -> bool:
    return lock_owner(lock_dir).get("token") == token


@contextmanager
def git_common_lock(name: str, timeout: int = 60, fallback_parent: Path | None = None) -> Any:
    common_lock = lock_parent() / name
    fallback_lock = fallback_parent / name if fallback_parent else None
    lock_dir = common_lock
    lock_timeout = lock_timeout_seconds(timeout)
    deadline = time.monotonic() + lock_timeout
    stale_after = stale_lock_seconds()
    token = uuid.uuid4().hex
    while True:
        try:
            lock_dir.parent.mkdir(parents=True, exist_ok=True)
            lock_dir.mkdir()
            (lock_dir / "owner").write_text(f"pid={os.getpid()}\ncreated_at={time.time():.0f}\ntoken={token}\n")
            break
        except FileExistsError:
            if reclaim_stale_lock(lock_dir, stale_after):
                continue
            if time.monotonic() >= deadline:
                die(f"timed out waiting for {lock_dir} lock")
            time.sleep(1)
        except OSError as exc:
            if exc.errno not in {errno.EACCES, errno.EPERM, errno.EROFS}:
                raise
            if fallback_lock is None or lock_dir == fallback_lock:
                raise
            lock_dir = fallback_lock
    try:
        yield
    finally:
        if lock_is_owned_by(lock_dir, token):
            try:
                (lock_dir / "owner").unlink()
            except FileNotFoundError:
                pass
            try:
                lock_dir.rmdir()
            except FileNotFoundError:
                pass


def command_exists(name: str) -> bool:
    # shutil.which, not a hand-rolled PATH walk: on Windows the executable is `gh.exe`, and a
    # walk testing `<dir>/gh` finds nothing — so this returned False for EVERY command and the
    # whole review flow died on "gh is required" from a machine that had gh on its PATH.
    # shutil.which consults PATHEXT there and behaves identically on POSIX.
    return shutil.which(name) is not None


def parse_state(path: Path) -> dict[str, str]:
    state: dict[str, str] = {}
    for raw in path.read_text().splitlines():
        if not raw or raw.startswith("#") or "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        state[key] = value
    return state


def write_state(path: Path, values: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    created_at = _dt.datetime.now(_dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    keys = [
        "PR",
        "REPO",
        "SHA",
        "BASELINE_REVIEW_ID",
        "BASELINE_PULL_COMMENT_ID",
        "BASELINE_ISSUE_COMMENT_ID",
        "BASELINE_FAILURE_COMMENT_ID",
        "REQUEST_COMMENT_ID",
        "REQUESTED_AT",
    ]
    lines = [f"{key}={values.get(key, '')}" for key in keys]
    lines.append(f"CREATED_AT={created_at}")
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text("\n".join(lines) + "\n")
    os.replace(tmp, path)


def state_values(state: dict[str, str]) -> dict[str, Any]:
    return {
        "PR": state.get("PR", ""),
        "REPO": state.get("REPO", ""),
        "SHA": state.get("SHA", ""),
        "BASELINE_REVIEW_ID": state.get("BASELINE_REVIEW_ID", 0),
        "BASELINE_PULL_COMMENT_ID": state.get("BASELINE_PULL_COMMENT_ID", 0),
        "BASELINE_ISSUE_COMMENT_ID": state.get("BASELINE_ISSUE_COMMENT_ID", 0),
        "BASELINE_FAILURE_COMMENT_ID": state.get("BASELINE_FAILURE_COMMENT_ID", 0),
        "REQUEST_COMMENT_ID": state.get("REQUEST_COMMENT_ID", ""),
        "REQUESTED_AT": state.get("REQUESTED_AT", ""),
    }


def recover_request_timestamp(path: Path, state: dict[str, str], repo: str) -> str:
    request_comment_id = state.get("REQUEST_COMMENT_ID", "")
    if not request_comment_id or state.get("REQUESTED_AT"):
        return state.get("REQUESTED_AT", "")
    created_at = str(gh_object(repo, f"issues/comments/{request_comment_id}").get("created_at") or "")
    if not created_at:
        raise GitHubError(f"codex-review: request comment {request_comment_id} has no created_at", EXIT_API)
    state["REQUESTED_AT"] = created_at
    write_state(path, state_values(state))
    return created_at


def has_complete_baselines(state: dict[str, str]) -> bool:
    keys = (
        "BASELINE_REVIEW_ID",
        "BASELINE_PULL_COMMENT_ID",
        "BASELINE_ISSUE_COMMENT_ID",
        "BASELINE_FAILURE_COMMENT_ID",
    )
    if not all(key in state for key in keys):
        return False
    for key in keys:
        try:
            int(state[key])
        except ValueError:
            return False
    return True


def int_value(value: str | int | None, name: str, *, positive: bool = False) -> int:
    try:
        parsed = int(str(value))
    except (TypeError, ValueError):
        die(f"{name} must be a positive integer" if positive else f"{name} must be an integer")
    if positive and parsed <= 0:
        die(f"{name} must be a positive integer")
    return parsed


def body(item: dict[str, Any]) -> str:
    return str(item.get("body") or "").replace("\n", " ")


def raw_body(item: dict[str, Any]) -> str:
    return str(item.get("body") or "")


def actor(item: dict[str, Any]) -> str:
    user = item.get("user") or {}
    return str(user.get("login") or "") if isinstance(user, dict) else ""


def item_id(item: dict[str, Any]) -> int:
    return int(item.get("id") or 0)


def is_fresh(item: dict[str, Any], baseline: int, requested_at: str, date_field: str) -> bool:
    if item_id(item) <= baseline:
        return False
    return not requested_at or str(item.get(date_field) or "") >= requested_at


def has_review_marker(text: str, sha: str) -> bool:
    marker = "Reviewed commit:**"
    return f"{marker} `{sha}`" in text or f"{marker} `{sha[:10]}`" in text


def body_cites_sha(text: str, sha: str) -> bool:
    """A permalink to the reviewed commit. Codex builds finding links as
    `/blob/<sha>/<path>#L..`, which names the commit as authoritatively as the
    `Reviewed commit:` line does -- and is present on rounds that omit that line."""
    return f"/blob/{sha}" in text or f"/blob/{sha[:10]}" in text


def review_names_sha(text: str, sha: str) -> bool:
    """Does this review answer for `sha`?

    NOT just the `Reviewed commit:` footer. Codex omits it on rounds whose body
    carries the findings inline: observed on blobly_emb#276 round 6, whose body
    opened with a `/blob/<sha>` permalink and a P1 finding and had no footer at
    all. Requiring the footer left the watcher reporting `pending` with four
    findings and a fifth in the body already posted -- the exact failure this
    tool exists to prevent, one signal shape later.

    Both forms are anchored to the sha, so neither can match a stale review.
    """
    return has_review_marker(text, sha) or body_cites_sha(text, sha)


def body_has_finding(text: str, sha: str) -> bool:
    return bool(re.search(r"!\[P[0-9] Badge\]", text)) or body_cites_sha(text, sha)


def has_exact_request_marker(item: dict[str, Any], sha: str, requester: str) -> bool:
    expected = f"@codex review\n\ncodex-review-state: {sha}"
    return actor(item) == requester and raw_body(item).replace("\r\n", "\n").strip() == expected


def current_head(repo: str, pr: str, timeout: float | None = None) -> str:
    head = gh_object(repo, f"pulls/{pr}", timeout=timeout).get("head") or {}
    if not isinstance(head, dict) or not head.get("sha"):
        raise GitHubError(f"codex-review: could not read current PR head for {repo}#{pr}", EXIT_API)
    return str(head["sha"])


def result_lines(result: dict[str, Any]) -> str:
    return "\n".join(f"{key}={value}" for key, value in result.items()) + "\n"


def fresh_finding_count(config: WatchConfig, deadline: float | None = None) -> int:
    """Inline findings by the reviewer, fresh for this round and naming this sha."""
    pull_comments = gh_items(config.repo, f"pulls/{config.pr}/comments", timeout=remaining_timeout(deadline))
    count = 0
    for comment in pull_comments:
        commit_id = str(comment.get("commit_id") or "")
        original_commit_id = str(comment.get("original_commit_id") or "")
        comment_body = body(comment)
        if actor(comment) != config.actor or not is_fresh(
            comment,
            config.baseline_pull_comment_id,
            config.requested_at,
            "created_at",
        ):
            continue
        if (
            config.sha in comment_body
            or config.sha[:10] in comment_body
            or commit_id.startswith(config.sha[:10])
            or original_commit_id.startswith(config.sha[:10])
        ):
            count += 1
    return count


def scan_once(config: WatchConfig, deadline: float | None = None) -> tuple[int, dict[str, Any]]:
    head = current_head(config.repo, config.pr, timeout=remaining_timeout(deadline))
    if head != config.sha:
        return EXIT_STALE_HEAD, {"RESULT": "stale_head", "PR": config.pr, "SHA": config.sha, "CURRENT_SHA": head}

    reviews = gh_items(config.repo, f"pulls/{config.pr}/reviews", timeout=remaining_timeout(deadline))
    matching_reviews = [
        item
        for item in reviews
        if actor(item) == config.actor
        and is_fresh(item, config.baseline_review_id, config.requested_at, "submitted_at")
        and review_names_sha(body(item), config.sha)
    ]
    review = max(matching_reviews, key=item_id, default=None)
    if review:
        count = fresh_finding_count(config, deadline=deadline)
        head = current_head(config.repo, config.pr, timeout=remaining_timeout(deadline))
        if head != config.sha:
            return EXIT_STALE_HEAD, {"RESULT": "stale_head", "PR": config.pr, "SHA": config.sha, "CURRENT_SHA": head}
        base = {"PR": config.pr, "SHA": config.sha, "SHA_PREFIX": config.sha[:10]}
        if count > 0 or body_has_finding(body(review), config.sha):
            return EXIT_FINDINGS, {"RESULT": "findings", **base, "REVIEW_ID": item_id(review), "PULL_COMMENTS": count}
        return EXIT_CLEAN, {"RESULT": "clean", **base, "REVIEW_ID": item_id(review)}

    issues = gh_items(config.repo, f"issues/{config.pr}/comments", timeout=remaining_timeout(deadline))
    clean_comments = [
        item
        for item in issues
        if actor(item) == config.actor
        and is_fresh(item, config.baseline_issue_comment_id, config.requested_at, "created_at")
        and has_review_marker(body(item), config.sha)
    ]
    clean = max(clean_comments, key=item_id, default=None)
    if clean:
        # Count the inline findings before believing it. The verdict and the findings arrive on
        # DIFFERENT channels, so a summary posted as a PR-level comment while findings sit inline
        # would otherwise report clean with the round outstanding -- the one direction that must
        # never be loosened, since a false clean merges unreviewed code.
        count = fresh_finding_count(config, deadline=deadline)
        head = current_head(config.repo, config.pr, timeout=remaining_timeout(deadline))
        if head != config.sha:
            return EXIT_STALE_HEAD, {"RESULT": "stale_head", "PR": config.pr, "SHA": config.sha, "CURRENT_SHA": head}
        base = {
            "PR": config.pr,
            "SHA": config.sha,
            "SHA_PREFIX": config.sha[:10],
            "ISSUE_COMMENT_ID": item_id(clean),
        }
        if count > 0:
            return EXIT_FINDINGS, {"RESULT": "findings", **base, "PULL_COMMENTS": count}
        return EXIT_CLEAN, {"RESULT": "clean", **base}

    failed_comments = [
        item
        for item in issues
        if actor(item) == config.actor
        and is_fresh(item, config.baseline_failure_comment_id, config.requested_at, "created_at")
        and "Something went wrong" in body(item)
    ]
    failed = max(failed_comments, key=item_id, default=None)
    if failed:
        head = current_head(config.repo, config.pr, timeout=remaining_timeout(deadline))
        if head != config.sha:
            return EXIT_STALE_HEAD, {"RESULT": "stale_head", "PR": config.pr, "SHA": config.sha, "CURRENT_SHA": head}
        return EXIT_FAILED, {
            "RESULT": "failed",
            "PR": config.pr,
            "SHA": config.sha,
            "SHA_PREFIX": config.sha[:10],
            "ISSUE_COMMENT_ID": item_id(failed),
        }

    return EXIT_PENDING, {
        "RESULT": "pending",
        "PR": config.pr,
        "SHA": config.sha,
        "SHA_PREFIX": config.sha[:10],
        "REVIEWS_AFTER_BASELINE": sum(1 for item in reviews if item_id(item) > config.baseline_review_id),
        "ISSUE_COMMENTS_AFTER_BASELINE": sum(1 for item in issues if item_id(item) > config.baseline_issue_comment_id),
    }


def watch_config(argv: list[str]) -> WatchConfig:
    pre = Parser(add_help=False)
    pre.add_argument("--state")
    known, _ = pre.parse_known_args(argv)
    state: dict[str, str] = {}
    state_file = Path(known.state) if known.state else None
    if state_file:
        if not state_file.is_file():
            die(f"state file not found: {state_file}")
        state = parse_state(state_file)

    parser = Parser(prog="scripts/codex_review_watch.sh")
    parser.add_argument("--state")
    parser.add_argument("--pr", default=state.get("PR"))
    parser.add_argument("--repo", default=state.get("REPO"))
    parser.add_argument("--sha", default=state.get("SHA"))
    parser.add_argument("--baseline-review-id", default=state.get("BASELINE_REVIEW_ID"))
    parser.add_argument("--baseline-issue-comment-id", default=state.get("BASELINE_ISSUE_COMMENT_ID"))
    parser.add_argument("--baseline-failure-comment-id", default=state.get("BASELINE_FAILURE_COMMENT_ID"))
    parser.add_argument("--baseline-pull-comment-id", default=state.get("BASELINE_PULL_COMMENT_ID"))
    parser.add_argument("--requested-at", default=state.get("REQUESTED_AT", ""))
    parser.add_argument("--interval", default=state.get("INTERVAL", "60"))
    parser.add_argument("--timeout", default=state.get("TIMEOUT", "3600"))
    parser.add_argument("--once", action="store_true")
    ns = parser.parse_args(argv)

    baseline_flags = {
        "--baseline-review-id",
        "--baseline-issue-comment-id",
        "--baseline-failure-comment-id",
        "--baseline-pull-comment-id",
    }
    seen_baselines = {
        flag
        for flag in baseline_flags
        if any(arg == flag or arg.startswith(f"{flag}=") for arg in argv)
    }
    if not ns.pr:
        die("--pr is required")
    if not ns.sha:
        die("--sha is required")
    repo = ns.repo or repo_slug()
    request_comment_id = state.get("REQUEST_COMMENT_ID", "")
    requested_at = str(ns.requested_at or "")
    if state_file and request_comment_id and not requested_at:
        requested_at = recover_request_timestamp(state_file, state, repo)
    if state_file and not requested_at and not has_complete_baselines(state):
        die("state file is missing freshness fields; re-request review to create a complete state")
    if not state_file and not ns.requested_at and seen_baselines != baseline_flags:
        die("direct mode requires --requested-at or all verdict freshness baselines")
    return WatchConfig(
        pr=str(ns.pr),
        repo=str(repo),
        sha=str(ns.sha),
        baseline_review_id=int_value(ns.baseline_review_id or 0, "--baseline-review-id"),
        baseline_issue_comment_id=int_value(ns.baseline_issue_comment_id or 0, "--baseline-issue-comment-id"),
        baseline_failure_comment_id=int_value(ns.baseline_failure_comment_id or 0, "--baseline-failure-comment-id"),
        baseline_pull_comment_id=int_value(ns.baseline_pull_comment_id or 0, "--baseline-pull-comment-id"),
        requested_at=requested_at,
        request_comment_id=request_comment_id,
        interval=int_value(ns.interval, "--interval", positive=True),
        timeout=int_value(ns.timeout, "--timeout", positive=True),
        once=bool(ns.once),
        actor=os.environ.get("CODEX_REVIEW_ACTOR", CODEX_ACTOR),
    )


def watch(argv: list[str]) -> int:
    config = watch_config(argv)
    start = time.monotonic()
    deadline = start + config.timeout
    # The last API failure, held so a persistent outage cannot masquerade as an ordinary
    # pending review: retrying consumes the window, and the expiry that follows would
    # otherwise report EXIT_PENDING -- "still waiting" -- for a watcher that never once
    # reached GitHub.
    last_api_error: GitHubError | None = None
    while True:
        try:
            rc, result = scan_once(config, deadline=deadline)
            last_api_error = None
        except WatchDeadlineExpired:
            if last_api_error is not None:
                print(str(last_api_error), file=sys.stderr)
                print(
                    f"codex-review: API failures consumed the whole {config.timeout}s window",
                    file=sys.stderr,
                )
                return EXIT_API
            print(f"codex-review: timed out after {config.timeout}s", file=sys.stderr)
            return EXIT_PENDING
        except GitHubError as exc:
            # A tracked watcher makes ~200 gh calls an hour; one 502 or secondary rate limit
            # must not end the round unread -- that is the failure this tool exists to prevent.
            # Retry on the next interval, but only while there IS one, and never for a hard
            # failure that no amount of waiting fixes. GitHubError.code carries gh's OWN exit
            # status, so classify on that -- and still report EXIT_API when giving up, which is
            # the contract callers watch for.
            if exc.code in HARD_API_CODES or config.once:
                print(str(exc), file=sys.stderr)
                return EXIT_API
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                print(str(exc), file=sys.stderr)
                return EXIT_API
            last_api_error = exc
            print(f"codex-review: transient API failure, retrying: {exc}", file=sys.stderr, flush=True)
            time.sleep(min(config.interval, remaining))
            continue
        print(result_lines(result), end="", flush=True)
        if rc in {EXIT_CLEAN, EXIT_FINDINGS, EXIT_FAILED, EXIT_STALE_HEAD}:
            return rc
        if config.once:
            return EXIT_PENDING
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            print(f"codex-review: timed out after {config.timeout}s", file=sys.stderr)
            return EXIT_PENDING
        time.sleep(min(config.interval, remaining))


def max_id(repo: str, path: str) -> int:
    return max((item_id(item) for item in gh_items(repo, path)), default=0)


def check_existing_state(path: Path, requested_pr: str, requested_repo: str, current_sha: str, review_actor: str) -> None:
    if not path.is_file():
        return
    state = parse_state(path)
    if not (
        state.get("PR") == requested_pr
        and state.get("REPO") == requested_repo
        and state.get("SHA") == current_sha
    ):
        return
    recover_request_timestamp(path, state, requested_repo)
    config = WatchConfig(
        pr=requested_pr,
        repo=requested_repo,
        sha=current_sha,
        baseline_review_id=int_value(state.get("BASELINE_REVIEW_ID", 0), "BASELINE_REVIEW_ID"),
        baseline_pull_comment_id=int_value(state.get("BASELINE_PULL_COMMENT_ID", 0), "BASELINE_PULL_COMMENT_ID"),
        baseline_issue_comment_id=int_value(state.get("BASELINE_ISSUE_COMMENT_ID", 0), "BASELINE_ISSUE_COMMENT_ID"),
        baseline_failure_comment_id=int_value(state.get("BASELINE_FAILURE_COMMENT_ID", 0), "BASELINE_FAILURE_COMMENT_ID"),
        requested_at=state.get("REQUESTED_AT", ""),
        request_comment_id=state.get("REQUEST_COMMENT_ID", ""),
        once=True,
        actor=review_actor,
    )
    try:
        rc, result = scan_once(config)
    except GitHubError as exc:
        print(str(exc), file=sys.stderr)
        die("could not determine whether the same-SHA review is still pending", EXIT_API)
    if rc == EXIT_PENDING:
        print(result_lines(result), end="", file=sys.stderr, flush=True)
        die("same-SHA review is still pending; wait for it before requesting another round")


def check_remote_pending(
    repo: str, pr: str, sha: str, requester: str, review_actor: str, force: bool = False
) -> None:
    comments = gh_items(repo, f"issues/{pr}/comments")
    marker = max(
        (item for item in comments if has_exact_request_marker(item, sha, requester)),
        key=item_id,
        default=None,
    )
    if not marker:
        return
    marker_id = item_id(marker)
    config = WatchConfig(
        pr=pr,
        repo=repo,
        sha=sha,
        baseline_issue_comment_id=marker_id,
        baseline_failure_comment_id=marker_id,
        request_comment_id=str(marker_id),
        requested_at=str(marker.get("created_at") or ""),
        once=True,
        actor=review_actor,
    )
    try:
        rc, result = scan_once(config)
    except GitHubError as exc:
        print(str(exc), file=sys.stderr)
        die(f"could not determine whether remote same-SHA request {marker_id} is still pending", EXIT_API)
    if rc == EXIT_PENDING:
        if force:
            # Deliberate recovery, NOT an age heuristic. Codex sometimes drops a trigger and
            # never posts a verdict or a failure, and the marker lives in the PR -- so deleting
            # the local state file does not clear it and the guard would wedge the PR forever.
            # A clock-based override would instead re-request over a review that is merely
            # slow, doubling it; this way the operator says so.
            print(
                f"codex-review: --force: re-requesting over pending request comment {marker_id}",
                file=sys.stderr,
            )
            return
        print(result_lines(result), end="", file=sys.stderr, flush=True)
        die(
            f"same-SHA review is already pending from request comment {marker_id}; "
            "wait for it, or pass --force to request again"
        )


def request(argv: list[str]) -> int:
    parser = Parser(prog="scripts/request_codex_review.sh")
    parser.add_argument("pr", nargs="?")
    parser.add_argument("--repo")
    parser.add_argument("--post", action="store_true")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--state-dir", default=".claude/reviews")
    ns = parser.parse_args(argv)
    if not ns.pr:
        parser.print_usage(sys.stderr)
        return EXIT_USAGE
    repo = ns.repo or repo_slug()
    if not ns.post:
        print("Manual mode cannot create a safe watcher baseline because the review result must be")
        print("tied to the actual request comment. Re-run with --post from an authorized account.")
        print()
        print("PR comment:")
        print("@codex review")
        return 0
    if not command_exists("gh"):
        die("gh is required")

    sha = gh_pr_head(repo, ns.pr)
    local_sha = git_stdout(["rev-parse", "HEAD"])
    if local_sha != sha:
        die(f"local HEAD {local_sha} does not match PR head {sha}; push/pull before requesting review")
    require_clean_worktree()

    state_path = Path(ns.state_dir) / f"pr-{ns.pr}.env"
    with git_common_lock(f"codex-review-pr-{ns.pr}.lock", fallback_parent=state_path.parent / ".locks"):
        review_actor = os.environ.get("CODEX_REVIEW_ACTOR", CODEX_ACTOR)
        check_existing_state(state_path, ns.pr, repo, sha, review_actor)
        requester = gh_user_login()
        check_remote_pending(repo, ns.pr, sha, requester, review_actor, force=ns.force)

        baseline_review_id = max_id(repo, f"pulls/{ns.pr}/reviews")
        baseline_pull_comment_id = max_id(repo, f"pulls/{ns.pr}/comments")
        # NOTE: no issue-comment baseline sweep here. The request comment posted below is
        # itself the baseline for both issue-comment id spaces (see values{} further down), so
        # reading the PR's whole comment history first is a paginated round trip inside the lock
        # whose result is discarded.
        latest_sha = gh_pr_head(repo, ns.pr)
        if latest_sha != sha:
            die(f"PR head changed from {sha} to {latest_sha} while preparing the request; retry")

        request_body = f"@codex review\n\ncodex-review-state: {sha}\n"
        request_url = gh_pr_comment(repo, ns.pr, request_body)
        match = re.search(r"issuecomment-(\d+)$", request_url)
        if not match:
            die(f"could not parse request comment id: {request_url}")
        request_comment_id = match.group(1)
        values = {
            "PR": ns.pr,
            "REPO": repo,
            "SHA": sha,
            "BASELINE_REVIEW_ID": baseline_review_id,
            "BASELINE_PULL_COMMENT_ID": baseline_pull_comment_id,
            "BASELINE_ISSUE_COMMENT_ID": request_comment_id,
            "BASELINE_FAILURE_COMMENT_ID": request_comment_id,
            "REQUEST_COMMENT_ID": request_comment_id,
            "REQUESTED_AT": "",
        }
        write_state(state_path, values)
        try:
            created_at = str(gh_object(repo, f"issues/comments/{request_comment_id}").get("created_at") or "")
        except GitHubError:
            print(
                f"codex-review: request was posted but its timestamp could not be read; state was saved at {state_path}",
                file=sys.stderr,
            )
            return EXIT_API
        values["REQUESTED_AT"] = created_at
        write_state(state_path, values)

    print(request_url)
    print(f"requested @codex review for {repo}#{ns.pr} at {sha}")
    print()
    print("Watch it with:")
    print(f"scripts/codex_review_watch.sh --state {shlex.quote(str(state_path))}")
    return 0


def unanswered(argv: list[str]) -> int:
    """List review findings that nothing replies to.

    A round is not handled until every finding carries a reply -- a PR-level summary is not an
    answer, and on #276 that left ten findings looking ignored. Doing this in the tool rather
    than as a shell one-liner is not tidiness: comparing findings against replies has to happen
    across ALL pages (`--paginate` hands back one array per page, so a per-page filter reports a
    finding as unanswered whenever its reply landed on a later page), and the obvious `jq -s`
    fix needs a standalone `jq`, which is absent from some agent environments -- the same trap
    this repo already records for `bc`.
    """
    parser = Parser(prog="scripts/codex_review.py unanswered")
    parser.add_argument("pr", nargs="?")
    parser.add_argument("--repo")
    parser.add_argument("--actor", default=CODEX_ACTOR)
    ns = parser.parse_args(argv)
    if not ns.pr:
        parser.print_usage(sys.stderr)
        return EXIT_USAGE
    repo = ns.repo or repo_slug()
    comments = gh_items(repo, f"pulls/{ns.pr}/comments")
    replied_to = {int(c["in_reply_to_id"]) for c in comments if c.get("in_reply_to_id")}
    open_findings = [
        c for c in comments if actor(c) == ns.actor and item_id(c) not in replied_to
    ]
    for c in open_findings:
        line = c.get("line") or c.get("original_line") or 0
        print(f"UNANSWERED {item_id(c)} {c.get('path')}:{line}")
    print(
        f"codex-review: {len(open_findings)} unanswered of "
        f"{sum(1 for c in comments if actor(c) == ns.actor)} findings",
        file=sys.stderr,
    )
    return EXIT_FINDINGS if open_findings else EXIT_CLEAN


def main(argv: list[str]) -> int:
    if not argv or argv[0] in {"-h", "--help"}:
        print("usage: scripts/codex_review.py {request,watch,unanswered} ...")
        return 0 if argv else EXIT_USAGE
    command, rest = argv[0], argv[1:]
    try:
        if command == "watch":
            return watch(rest)
        if command == "request":
            return request(rest)
        if command == "unanswered":
            return unanswered(rest)
        die(f"unknown command: {command}")
    except CodexReviewError as exc:
        print(f"codex-review: {exc}", file=sys.stderr)
        return exc.code
    except GitHubError as exc:
        print(str(exc), file=sys.stderr)
        return EXIT_API
    except BrokenPipeError:
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
