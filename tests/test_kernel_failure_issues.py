# SPDX-License-Identifier: GPL-2.0-or-later
"""Exercise the issue reporter with simulated scheduled runs and an in-memory GitHub API."""

import importlib.util
import json
import os
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/report-kernel-failure.py"
SPEC = importlib.util.spec_from_file_location("report_kernel_failure", SCRIPT)
reporter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reporter)

REPO = "ludohirst/macbook12-audio-akmod"
OLDER = "7.2.11-300.fc45.x86_64"
STABLE = "7.2.15-300.fc45.x86_64"
TESTING = "7.3.3-300.fc45.x86_64"
BOT = {"login": "github-actions[bot]", "id": 41898282}


class FakeIssues:
    def __init__(self):
        self.issues = []
        self.jobs = {}

    def api(self, method, path, data=None):
        endpoint = f"repos/{REPO}/issues"
        url = urlsplit(path)
        if method == "GET" and url.path in self.jobs:
            return {"jobs": self.jobs[url.path]}
        if method == "GET" and url.path.lstrip("/") == endpoint:
            query = parse_qs(url.query)
            assert query["state"] == ["open"]
            issues = [i for i in self.issues if i["state"] == "open"]
            if "creator" in query:
                issues = [i for i in issues if i["user"]["login"] == query["creator"][0]]
            page = int(query.get("page", ["1"])[0])
            size = int(query.get("per_page", ["30"])[0])
            return issues[(page - 1) * size : page * size]
        if method == "POST" and url.path.lstrip("/") == endpoint:
            number = len(self.issues) + 1
            issue = dict(data, number=number, user=BOT, state="open")
            self.issues.append(issue)
            return issue
        if method == "PATCH" and url.path.lstrip("/").startswith(endpoint + "/"):
            issue = self.issues[int(url.path.rsplit("/", 1)[1]) - 1]
            issue.update(data)
            return issue
        raise AssertionError(f"Unexpected request {method} {path}")


class KernelIssueTests(unittest.TestCase):
    def setUp(self):
        self.github = FakeIssues()
        self.enterContext(patch.object(reporter, "api", self.github.api))

    def report(self, run, *, track="stable", phase="build", kernel=STABLE,
               detail="Build the per-kernel akmod", lane="stable", targets=(OLDER, STABLE),
               context=None, attempt=1, failed_attempt=None):
        failed_attempt = attempt if failed_attempt is None else failed_attempt
        job_url = f"https://github.com/{REPO}/actions/runs/{run}/job/{run + 1000}"
        jobs_path = f"repos/{REPO}/actions/runs/{run}/attempts"
        self.github.jobs[f"{jobs_path}/{attempt}/jobs"] = []
        self.github.jobs[f"{jobs_path}/{failed_attempt}/jobs"] = [{
            "name": "Build and verify two kernels offline", "conclusion": "failure",
            "html_url": job_url, "steps": [{"name": "Select two kernels and stage build inputs",
                                            "conclusion": "failure"}],
        }]
        if context is None:
            context = json.dumps(f"{phase}\t{kernel}\t{detail}\t{lane}\n")
        env = {
            "GITHUB_REPOSITORY": REPO, "GITHUB_RUN_ID": str(run),
            "GITHUB_RUN_ATTEMPT": str(attempt), "CHECK_TRACK": track,
            "FAILURE_CONTEXT": context, "KNOWN_TARGETS": json.dumps("\n".join(targets)),
        }
        with patch.dict(os.environ, env):
            reporter.main()
        return job_url

    def test_same_kernel_and_failure_updates_open_issue_even_if_companion_changes(self):
        self.report(100)
        self.assertEqual(len(self.github.issues), 1)
        issue = self.github.issues[0]
        self.assertEqual(issue["title"], f"Audio akmod failed on Fedora 45 kernel {STABLE}")
        self.assertIn(STABLE, issue["body"])
        self.assertIn("stable", issue["body"])
        self.assertIn("build", issue["body"].lower())
        new_url = self.report(101, track="updates-testing", targets=(STABLE, TESTING))
        self.assertEqual(len(self.github.issues), 1)
        self.assertIn(new_url, issue["body"])
        self.report(99)
        self.assertIn(new_url, issue["body"])

    def test_testing_run_can_fail_on_the_stable_companion(self):
        options = dict(track="updates-testing", targets=(STABLE, TESTING),
                       phase="module-verification", detail="Check module vermagic")
        self.report(110, **options)
        issue = self.github.issues[0]
        self.assertIn(STABLE, issue["title"])
        self.assertNotIn(TESTING, issue["title"])
        self.assertIn("stable", issue["body"])
        self.assertIn("updates-testing", issue["body"])
        self.assertIn("vermagic", issue["body"])
        self.report(111, kernel=TESTING, lane="updates-testing", **options)
        self.assertEqual(len(self.github.issues), 2)
        self.assertIn(TESTING, self.github.issues[1]["title"])
        self.report(112, phase="rollback", detail="Restore stock module")
        self.assertEqual(len(self.github.issues), 3)
        self.assertIn("rollback", self.github.issues[2]["body"].lower())

    def test_setup_failure_before_kernel_selection_and_shared_build_failure(self):
        options = dict(track="updates-testing", phase="setup", kernel="-", lane="unknown",
                       detail="Select Fedora kernel targets", targets=())
        self.report(120, **options)
        body = self.github.issues[0]["body"]
        self.assertIn("setup", body.lower())
        self.assertIn("updates-testing", body)
        self.assertIn("could not be attributed to one kernel", body)
        self.assertIn("none recorded", body)
        self.assertIn(self.report(121, **options), self.github.issues[0]["body"])
        self.report(122, kernel="-", lane="unknown", detail="Build shared source RPM")
        self.assertEqual(len(self.github.issues), 2)
        issue = self.github.issues[1]
        for kernel in [OLDER, STABLE]:
            self.assertIn(kernel, issue["body"])
            self.assertNotIn(kernel, issue["title"])
        new_url = self.report(123, kernel="-", lane="unknown", detail="Build shared source RPM",
                              targets=(STABLE, OLDER))
        self.assertEqual(len(self.github.issues), 2)
        self.assertIn(new_url, issue["body"])

    def test_closed_or_copied_issue_does_not_block_a_new_report(self):
        self.report(130)
        self.github.issues[0]["state"] = "closed"
        self.report(131)
        self.assertEqual(len(self.github.issues), 2)
        self.github.issues[1]["user"] = {"login": "another-user", "id": 123}
        link = self.report(132)
        self.assertEqual(len(self.github.issues), 3)
        self.assertIn(link, self.github.issues[2]["body"])
        self.assertNotIn(link, self.github.issues[1]["body"])

    def test_download_error_is_separate_from_driver_build_for_same_kernel(self):
        self.report(140, phase="download", detail="Download signed kernel RPMs")
        self.report(141)
        self.assertEqual(len(self.github.issues), 2)
        self.assertIn("download", self.github.issues[0]["body"].lower())
        self.assertIn("infrastructure", self.github.issues[0]["body"])
        self.assertIn("build", self.github.issues[1]["body"].lower())

    def test_no_context_reports_failed_step_and_links_previous_failed_job_on_retry(self):
        link = self.report(150, attempt=2, failed_attempt=1, context="", targets=())
        issue = self.github.issues[0]
        self.assertIn(link, issue["body"])
        self.assertIn("attempt 1", issue["body"])
        self.assertIn("Select two kernels and stage build inputs", issue["body"])
        self.assertIn("could not be attributed to one kernel", issue["body"])
        self.assertIn("infrastructure", issue["body"])
        self.assertIn("setup", issue["title"])


if __name__ == "__main__":
    unittest.main()
