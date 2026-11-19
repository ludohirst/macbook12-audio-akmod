#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Open or refresh an issue for a failed scheduled Fedora 45 check."""

import hashlib
import json
import os
import re
import subprocess
from typing import NamedTuple


KERNEL = re.compile(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?-[0-9]+(?:\.[0-9]+)*\.fc45\.x86_64")
PHASES = ("setup", "download", "build", "module-verification", "rollback")
TRACKS = ("stable", "updates-testing")
BOT_ID = 41898282  # github-actions[bot] on github.com
LAST_RUN = re.compile(r"<!-- latest-actions-run: (\d+) (\d+) -->")


def api(method, path, data=None):
    if not os.environ.get("GH_TOKEN"):
        raise SystemExit("GH_TOKEN is required for issue reporting")
    command = ["gh", "api", "--hostname", "github.com", "--method", method, path]
    if data is not None:
        command.extend(["--input", "-"])
    result = subprocess.run(
        command, input=json.dumps(data) if data is not None else None,
        stdout=subprocess.PIPE, text=True, check=True,
    )
    return json.loads(result.stdout)


class Failure(NamedTuple):
    phase: str
    kernel: str
    detail: str
    lane: str


def failed_job(repo, run_id, attempt):
    # Rerunning only the reporter can leave the failed build in an earlier attempt.
    for number in range(attempt, 0, -1):
        path = f"repos/{repo}/actions/runs/{run_id}/attempts/{number}/jobs?per_page=100"
        for job in api("GET", path)["jobs"]:
            if job["name"] != "Build and verify two kernels offline":
                continue
            if job["conclusion"] not in ("failure", "timed_out", "startup_failure"):
                raise SystemExit("The build job did not fail")
            url = job["html_url"]
            prefix = f"https://github.com/{repo}/actions/runs/{run_id}/job/"
            if not re.fullmatch(re.escape(prefix) + r"[1-9][0-9]*", url):
                raise SystemExit("Unexpected build job URL")
            step = next((s["name"] for s in (job.get("steps") or []) if s["conclusion"] == "failure"), "")
            return number, url, step
    raise SystemExit("Could not find the failed build job")


def text_output(name):
    try:
        value = json.loads(os.environ.get(name) or '""')
    except ValueError:
        return ""
    return value if isinstance(value, str) else ""


def plain_description(value):
    return (0 < len(value) <= 240 and value.isprintable()
            and not any(char in value for char in "`@<>[]"))


def read_failure(step):
    fields = text_output("FAILURE_CONTEXT").removesuffix("\n").split("\t")
    if len(fields) == 4:
        record = Failure(*fields)
        if (record.phase in PHASES and record.lane in (*TRACKS, "unknown")
                and (record.kernel == "-" or KERNEL.fullmatch(record.kernel))
                and plain_description(record.detail)):
            return record
    return Failure("workflow", "-", step if plain_description(step) else "Build job", "unknown")


def make_report(record, targets, track, run_id, attempt, job_url):
    phase = record.phase.replace("-", " ")
    kernel = record.kernel
    infrastructure = record.phase in ("setup", "download")
    # Separate failures at different checkpoints, but ignore the companion
    # kernel if a command was already working on one particular release.
    identity = [record.phase, record.detail, kernel]
    if kernel == "-":
        identity.extend([track, sorted(set(targets))])
    digest = hashlib.sha256(json.dumps(identity).encode()).hexdigest()
    marker = f"<!-- fedora45-akmod-failure: {digest} -->"

    if phase == "workflow":
        title = "Fedora 45 audio akmod workflow failed (kernel unknown)"
    elif infrastructure:
        title = f"Fedora 45 audio akmod check failed during {phase}"
        if kernel != "-":
            title += f" for kernel {kernel}"
    elif kernel != "-":
        title = f"Audio akmod failed on Fedora 45 kernel {kernel}"
    else:
        title = f"Audio akmod failed during {phase} on Fedora 45 (kernel unknown)"

    lines = [f"Scheduled check: **{track}**"]
    if kernel == "-":
        lines.append("The failure could not be attributed to one kernel.")
        known = ", ".join(f"`{target}`" for target in targets)
        lines.append(f"Known targets: {known or 'none recorded'}.")
    else:
        lane = record.lane if record.lane != "unknown" else "repository unknown"
        lines.append(f"Kernel: `{kernel}` ({lane}).")
    lines.append(f"Failed during **{phase}**: `{record.detail.rstrip('.')}`.")
    if phase == "workflow":
        lines.append("No usable CI checkpoint was recorded. The job logs show the last Actions step.")
    elif infrastructure:
        lines.append("This is a CI infrastructure failure.")
    lines.append(f"[Failed Actions job logs (run {run_id}, attempt {attempt})]({job_url})")
    lines.extend([marker, f"<!-- latest-actions-run: {run_id} {attempt} -->"])
    return marker, title, "\n\n".join(lines)


def upsert_issue(repo, marker, title, body, run_id, attempt):
    path = f"repos/{repo}/issues"
    page = 1
    while True:
        issues = api("GET", f"{path}?state=open&creator=github-actions%5Bbot%5D&per_page=100&page={page}")
        for issue in issues:
            existing = issue.get("body") or ""
            if (issue.get("pull_request") is not None or issue["state"] != "open"
                    or issue["user"]["id"] != BOT_ID or marker not in existing.splitlines()):
                continue
            previous = LAST_RUN.search(existing)
            if previous and tuple(map(int, previous.groups())) >= (run_id, attempt):
                print(f"Issue #{issue['number']} already records this or a newer run.")
                return
            api("PATCH", f"{path}/{issue['number']}", {"body": body})
            print(f"Updated issue #{issue['number']}.")
            return
        if len(issues) < 100:
            break
        page += 1
    created = api("POST", path, {"title": title, "body": body})
    print(f"Opened issue #{created['number']}.")


def main():
    repo = os.environ["GITHUB_REPOSITORY"]
    run_id = int(os.environ["GITHUB_RUN_ID"])
    attempt = int(os.environ["GITHUB_RUN_ATTEMPT"])
    track = os.environ["CHECK_TRACK"]
    if repo != "ludohirst/macbook12-audio-akmod" or track not in TRACKS or min(run_id, attempt) < 1:
        raise SystemExit("Unexpected scheduled workflow context")
    attempt, job_url, step = failed_job(repo, run_id, attempt)
    record = read_failure(step)
    targets = [line for line in text_output("KNOWN_TARGETS").splitlines() if KERNEL.fullmatch(line)]
    marker, title, body = make_report(record, targets, track, run_id, attempt, job_url)
    upsert_issue(repo, marker, title, body, run_id, attempt)


if __name__ == "__main__":
    main()
