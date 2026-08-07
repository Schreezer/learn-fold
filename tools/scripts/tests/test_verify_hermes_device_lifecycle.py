import hashlib
import importlib.util
import json
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).parents[1] / "verify-hermes-device-lifecycle.py"
SPEC = importlib.util.spec_from_file_location("verify_hermes_device_lifecycle", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


def compact(value):
    return json.dumps(value, separators=(",", ":"), sort_keys=True)


class HermesDeviceLifecycleVerifierTests(unittest.TestCase):
    expected_model = "learnfoldflawless"
    expected_bundle_id = "com.chirag.learnfold"

    @classmethod
    def setUpClass(cls):
        cls.repository = SCRIPT_PATH.parents[2]
        cls.native_package = cls.repository / "shared/third_party/NativeBlockEditor"
        subprocess.run(
            [
                "swift",
                "build",
                "--package-path",
                str(cls.native_package),
                "--product",
                "native-editor-evidence-helper",
            ],
            capture_output=True,
            text=True,
            timeout=180,
            check=True,
        )
        binary_path = subprocess.run(
            ["swift", "build", "--package-path", str(cls.native_package), "--show-bin-path"],
            capture_output=True,
            text=True,
            timeout=60,
            check=True,
        ).stdout.strip()
        cls.native_helper = Path(binary_path) / "native-editor-evidence-helper"
        cls.media_directory = tempfile.TemporaryDirectory()
        video_path = Path(cls.media_directory.name) / "lifecycle.mp4"
        image_path = Path(cls.media_directory.name) / "final.png"
        subprocess.run(
            [
                "ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=black:s=64x64:d=1.1",
                "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-y", str(video_path),
            ],
            capture_output=True,
            text=True,
            timeout=60,
            check=True,
        )
        subprocess.run(
            [
                "ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=black:s=64x64",
                "-frames:v", "1", "-y", str(image_path),
            ],
            capture_output=True,
            text=True,
            timeout=60,
            check=True,
        )
        cls.video_bytes = video_path.read_bytes()
        cls.image_bytes = image_path.read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.media_directory.cleanup()

    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.workspace_id = "workspace-proof"
        self.thread_id = "thread-proof"
        self.workspace = self.root / "export" / "Apps" / "Courses" / self.workspace_id
        self.course_dir = self.workspace / ".course"
        self.bridge_state = self.root / "bridge"
        self.capture_dir = self.root / "capture"
        self.manifest_path = self.root / "run-manifest.json"
        self.course_dir.mkdir(parents=True)
        self.bridge_state.mkdir()
        self.capture_dir.mkdir()
        self.mutation_markdown = (
            "# Phone Tool Proof\n"
            "\n"
            "The phone executes the request locally and returns structured evidence to Hermes.\n"
            "\n"
            "```swift\n"
            "let executedOn = \"mobile_device\"\n"
            "print(executedOn)\n"
            "```\n"
            "\n"
            "Exercise: Change the value, then explain why Hermes must wait for the returned result."
        )
        markdown_path = self.root / "final-markdown.md"
        markdown_path.write_text(self.mutation_markdown, encoding="utf-8")
        fixture_result = subprocess.run(
            [
                str(self.native_helper),
                "create-fixture",
                str(self.course_dir / "course-library.sqlite"),
                str(markdown_path),
            ],
            capture_output=True,
            text=True,
            timeout=60,
            check=True,
        )
        self.native_fixture = json.loads(fixture_result.stdout)
        self.page_id = self.native_fixture["lessonPageID"]
        self.final_markdown = self.native_fixture["postResult"]["markdown"]
        self._write_fixture()

    def tearDown(self):
        self.temporary_directory.cleanup()

    def write_json(self, path, value):
        path.write_text(json.dumps(value), encoding="utf-8")

    def read_json(self, path):
        return json.loads(path.read_text(encoding="utf-8"))

    def user_text(self, text, item_id="user-message"):
        return {
            "type": "userMessage",
            "id": item_id,
            "content": [{"type": "text", "text": text}],
        }

    def agent_text(self, text, item_id="agent-message"):
        return {"type": "agentMessage", "id": item_id, "text": text}

    def tool_call(self, name, arguments):
        return self.agent_text(
            compact({"learnfold_tool_call": {"name": name, "arguments": arguments}}),
            f"agent-{name}",
        )

    def tool_result(self, entry):
        result = {
            "call_id": entry["id"],
            "executed_on": "mobile_device",
            "name": entry["toolName"],
            "output": entry["output"],
            "source_turn_id": entry["sourceTurnID"],
            "success": True,
            "workspace_id": self.workspace_id,
        }
        if entry["toolName"] == "present_course_plan":
            result["approval_status"] = "pending"
            continuation = VERIFIER.PLAN_CONTINUATION
        else:
            continuation = VERIFIER.TOOL_CONTINUATION
        text = compact({"learnfold_tool_result": result}) + "\n\n" + continuation
        return self.user_text(text, f"user-{entry['id']}")

    def turn(self, turn_id, *items):
        return {"id": turn_id, "items": list(items), "status": "completed"}

    def journal_entry(
        self,
        call_id,
        source,
        result,
        name,
        arguments,
        output,
        chain_root,
        chain_step,
    ):
        return {
            "id": call_id,
            "workspaceID": self.workspace_id,
            "threadID": self.thread_id,
            "sourceTurnID": source,
            "resultTurnID": result,
            "toolName": name,
            "argumentsJSON": compact(arguments),
            "phase": "completed",
            "success": True,
            "output": output,
            "resultSubmissionAttempts": 1,
            "chainRootTurnID": chain_root,
            "chainStep": chain_step,
            "updatedAt": chain_step,
        }

    def _write_fixture(self):
        self.plan = {
            "plan_id": "phone-tool-proof",
            "revision": 1,
            "title": "Phone Tool Proof",
            "summary": "A tiny proof course.",
            "outcome": "Explain the phone-owned Hermes tool lifecycle.",
            "starting_point": "Beginner with a basic agent model.",
            "focus_gap": "Execution, evidence, and recovery.",
            "estimated_duration": "10 minutes",
            "chapters": [
                {
                    "id": "proof",
                    "title": "Phone Proof",
                    "objective": "Explain the complete lifecycle.",
                    "deliverables": ["One verified lesson"],
                }
            ],
        }
        plan_arguments = {**self.plan, "workspace_id": self.workspace_id}
        pre_arguments = {"workspace_id": self.workspace_id, "id": self.page_id}
        mutation_arguments = {
            "workspace_id": self.workspace_id,
            "page_id": self.page_id,
            "command": "replace_content",
            "expected_revision": 1,
            "new_str": self.mutation_markdown,
            "properties": {"generation_status": "generated"},
        }
        post_arguments = {"workspace_id": self.workspace_id, "id": self.page_id}
        pre_output = compact(self.native_fixture["preResult"])
        final_output = compact(self.native_fixture["postResult"])
        mutation_output = compact(self.native_fixture["mutationResult"])
        entries = [
            self.journal_entry(
                "call-plan",
                "turn-plan-source",
                "turn-plan-result",
                "present_course_plan",
                plan_arguments,
                "Plan displayed and awaiting approval.",
                "turn-plan-source",
                1,
            ),
            self.journal_entry(
                "call-fetch-before",
                "turn-approval",
                "turn-fetch-before-result",
                "native-editor-fetch",
                pre_arguments,
                pre_output,
                "turn-approval",
                1,
            ),
            self.journal_entry(
                "call-update",
                "turn-fetch-before-result",
                "turn-update-result",
                "native-editor-update-page",
                mutation_arguments,
                mutation_output,
                "turn-approval",
                2,
            ),
            self.journal_entry(
                "call-fetch-after",
                "turn-update-result",
                "turn-fetch-after-result",
                "native-editor-fetch",
                post_arguments,
                final_output,
                "turn-approval",
                3,
            ),
        ]
        self.write_json(self.course_dir / "remote-hermes-tool-journal.json", entries)
        self.write_json(self.course_dir / "remote-hermes-submissions.json", [])
        self.write_json(self.course_dir / "approved-plan.json", self.plan)
        by_id = {entry["id"]: entry for entry in entries}
        approval = VERIFIER.normalized_approval_message(self.plan)
        turns = [
            self.turn("turn-plan-source", self.tool_call("present_course_plan", plan_arguments)),
            self.turn(
                "turn-plan-result",
                self.tool_result(by_id["call-plan"]),
                self.agent_text("The plan is ready for review."),
            ),
            self.turn(
                "turn-approval",
                self.user_text(approval, "approval-message"),
                self.tool_call("native-editor-fetch", pre_arguments),
            ),
            self.turn(
                "turn-fetch-before-result",
                self.tool_result(by_id["call-fetch-before"]),
                self.tool_call("native-editor-update-page", mutation_arguments),
            ),
            self.turn(
                "turn-update-result",
                self.tool_result(by_id["call-update"]),
                self.tool_call("native-editor-fetch", post_arguments),
            ),
            self.turn(
                "turn-fetch-after-result",
                self.tool_result(by_id["call-fetch-after"]),
                self.agent_text("Done — the phone result was returned and the lesson is verified."),
            ),
        ]
        self.write_json(
            self.bridge_state / "turns.json",
            {"threads": {self.thread_id: turns}, "activeRuns": {}, "submissionIntents": {}},
        )
        self.write_json(
            self.bridge_state / "threads.json",
            {
                "bindings": [
                    {
                        "threadId": self.thread_id,
                        "hermesSessionId": "session-proof",
                        "model": self.expected_model,
                        "cwd": f"/__learnfold_device_owned__/{self.workspace_id}",
                        "approvalPolicy": "never",
                        "approvalsReviewer": "user",
                    }
                ]
            },
        )
        (self.capture_dir / "lifecycle.mp4").write_bytes(self.video_bytes)
        (self.capture_dir / "final.png").write_bytes(self.image_bytes)
        device_info_raw = self.capture_dir / "device-info.raw.json"
        app_info_raw = self.capture_dir / "app-info.raw.json"
        self.write_json(device_info_raw, {"result": {"device": "synthetic unit-test fixture"}})
        self.write_json(app_info_raw, {"result": {"apps": ["synthetic unit-test fixture"]}})
        self.write_json(
            self.capture_dir / "device-info.json",
            {
                "source": "xcrun devicectl device info details",
                "raw_sha256": hashlib.sha256(device_info_raw.read_bytes()).hexdigest(),
                "reality": "physical",
                "name": "Aeon",
                "udid": "00008150-00060CE12684401C",
                "model": "iPhone 17 Pro Max",
                "os_version": "27.0",
                "os_build": "24A5390f",
            },
        )
        self.write_json(
            self.capture_dir / "app-info.json",
            {
                "source": "xcrun devicectl device info apps",
                "raw_sha256": hashlib.sha256(app_info_raw.read_bytes()).hexdigest(),
                "device_udid": "00008150-00060CE12684401C",
                "bundle_id": self.expected_bundle_id,
                "signed": True,
                "team_id": "UF4L3PL7UG",
                "version": "1.0",
                "build": "1",
            },
        )
        signing_info_raw = self.capture_dir / "signing-info.raw.txt"
        signing_info_raw.write_text(
            "synthetic fixture: valid on disk\n"
            "synthetic fixture: satisfies its Designated Requirement\n"
            f"Identifier={self.expected_bundle_id}\n"
            "TeamIdentifier=UF4L3PL7UG\n"
            "CDHash=0123456789abcdef0123456789abcdef01234567\n"
            "Authority=Apple Development: Synthetic Fixture (TESTTEAM)\n"
            f"CFBundleIdentifier={self.expected_bundle_id}\n"
            "CFBundleShortVersionString=1.0\n"
            "CFBundleVersion=1\n"
        )
        self.write_json(
            self.capture_dir / "signing-info.json",
            {
                "source": "codesign -vv --strict; codesign -dvvv; Info.plist",
                "raw_sha256": hashlib.sha256(signing_info_raw.read_bytes()).hexdigest(),
                "bundle_id": self.expected_bundle_id,
                "team_id": "UF4L3PL7UG",
                "version": "1.0",
                "build": "1",
                "cdhash": "0123456789abcdef0123456789abcdef01234567",
                "authority": "Apple Development: Synthetic Fixture (TESTTEAM)",
            },
        )
        self.refresh_manifest()

    def artifact_record(self, path):
        return {
            "path": str(path.relative_to(self.root)),
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        }

    def refresh_manifest(self):
        artifacts = {
            "tool_journal": self.artifact_record(self.course_dir / "remote-hermes-tool-journal.json"),
            "submissions": self.artifact_record(self.course_dir / "remote-hermes-submissions.json"),
            "approved_plan": self.artifact_record(self.course_dir / "approved-plan.json"),
            "course_database": self.artifact_record(self.course_dir / "course-library.sqlite"),
            "turns": self.artifact_record(self.bridge_state / "turns.json"),
            "threads": self.artifact_record(self.bridge_state / "threads.json"),
            "screen_record": self.artifact_record(self.capture_dir / "lifecycle.mp4"),
            "final_screenshot": self.artifact_record(self.capture_dir / "final.png"),
            "device_info": self.artifact_record(self.capture_dir / "device-info.json"),
            "app_info": self.artifact_record(self.capture_dir / "app-info.json"),
            "device_info_raw": self.artifact_record(self.capture_dir / "device-info.raw.json"),
            "app_info_raw": self.artifact_record(self.capture_dir / "app-info.raw.json"),
            "signing_info": self.artifact_record(self.capture_dir / "signing-info.json"),
            "signing_info_raw": self.artifact_record(self.capture_dir / "signing-info.raw.txt"),
        }
        database_path = self.course_dir / "course-library.sqlite"
        for suffix, key in (("-wal", "course_database_wal"), ("-shm", "course_database_shm")):
            sidecar = Path(f"{database_path}{suffix}")
            if sidecar.exists():
                artifacts[key] = self.artifact_record(sidecar)
        self.write_json(
            self.manifest_path,
            {
                "schema_version": 1,
                "fresh_workspace": True,
                "workspace_id": self.workspace_id,
                "expected_model": self.expected_model,
                "device": {
                    "reality": "physical",
                    "name": "Aeon",
                    "udid": "00008150-00060CE12684401C",
                    "model": "iPhone 17 Pro Max",
                    "os_version": "27.0",
                    "os_build": "24A5390f",
                },
                "app": {
                    "bundle_id": self.expected_bundle_id,
                    "signed": True,
                    "team_id": "UF4L3PL7UG",
                    "version": "1.0",
                    "build": "1",
                },
                "lifecycle": {
                    "recording_started_at": "2026-08-01T08:00:00+05:30",
                    "backgrounded_at": "2026-08-01T08:00:10+05:30",
                    "foregrounded_at": "2026-08-01T08:00:20+05:30",
                    "completed_at": "2026-08-01T08:00:30+05:30",
                },
                "artifacts": artifacts,
            },
        )

    def verify(self):
        return VERIFIER.verify_workspace(
            self.workspace,
            self.bridge_state,
            self.manifest_path,
            self.expected_model,
            self.expected_bundle_id,
            self.native_helper,
            typecheck_swift=False,
        )

    def mutate_json(self, path, mutator):
        value = self.read_json(path)
        mutator(value)
        self.write_json(path, value)
        self.refresh_manifest()

    def test_accepts_complete_correlated_capture(self):
        summary = self.verify()
        self.assertEqual(summary["status"], "artifact_consistency_verified")
        self.assertEqual(summary["tool_calls"], 4)
        self.assertEqual(summary["lesson_revision_before"], 1)
        self.assertEqual(summary["lesson_revision_after"], 2)
        self.assertNotEqual(self.mutation_markdown, self.final_markdown)
        database = sqlite3.connect(self.course_dir / "course-library.sqlite")
        unrelated_history_count = database.execute(
            "SELECT COUNT(*) FROM page_history WHERE page_id != ?", (self.page_id,)
        ).fetchone()[0]
        receipt_count = database.execute("SELECT COUNT(*) FROM sync_mutation_receipts").fetchone()[0]
        database.close()
        self.assertGreater(unrelated_history_count, 0)
        self.assertEqual(receipt_count, 0)

    def test_accepts_production_search_update_content_terminal_chain(self):
        entries = self.read_json(self.course_dir / "remote-hermes-tool-journal.json")
        plan, pre_fetch, mutation, _post_fetch = entries
        self_arguments = {"workspace_id": self.workspace_id, "id": "self"}
        self_fetch = self.journal_entry(
            "call-fetch-self",
            "turn-approval",
            "turn-fetch-self-result",
            "native-editor-fetch",
            self_arguments,
            compact(
                {
                    "object": "self",
                    "workspace": {"id": self.workspace_id, "name": "Native Editor"},
                    "current_tool_access": {"fetch": "available", "search": "available"},
                }
            ),
            "turn-approval",
            1,
        )
        search_arguments = {
            "workspace_id": self.workspace_id,
            "query": "Phone Tool Proof",
            "limit": 10,
        }
        search = self.journal_entry(
            "call-search",
            "turn-fetch-self-result",
            "turn-search-result",
            "native-editor-search",
            search_arguments,
            compact(
                {
                    "object": "list",
                    "results": [
                        {
                            "object": "page",
                            "id": "chapter-page",
                            "title": "Phone Proof",
                            "url": "native-editor://page/chapter-page",
                        }
                    ],
                    "has_more": False,
                }
            ),
            "turn-approval",
            2,
        )
        chapter_arguments = {"workspace_id": self.workspace_id, "id": "chapter-page"}
        chapter_fetch = self.journal_entry(
            "call-fetch-chapter",
            "turn-search-result",
            "turn-fetch-chapter-result",
            "native-editor-fetch",
            chapter_arguments,
            compact(
                {
                    "object": "page_markdown",
                    "id": "chapter-page",
                    "title": "Phone Proof",
                    "revision": 1,
                    "markdown": "# Phone Proof\n<page url=\"native-editor://page/%s\">Lesson</page>"
                    % self.page_id,
                    "course_metadata": {
                        "role": "chapter",
                        "generation_status": "pending_generation",
                    },
                }
            ),
            "turn-approval",
            3,
        )
        pre_fetch["sourceTurnID"] = "turn-fetch-chapter-result"
        pre_fetch["chainStep"] = 4
        pre_output = json.loads(pre_fetch["output"])
        mutation_arguments = json.loads(mutation["argumentsJSON"])
        mutation_arguments.pop("new_str")
        mutation_arguments["command"] = "update_content"
        mutation_arguments["content_updates"] = [
            {
                "old_str": pre_output["markdown"],
                "new_str": self.mutation_markdown,
            }
        ]
        mutation["argumentsJSON"] = compact(mutation_arguments)
        mutation["chainStep"] = 5
        self.write_json(
            self.course_dir / "remote-hermes-tool-journal.json",
            [plan, self_fetch, search, chapter_fetch, pre_fetch, mutation],
        )
        by_id = {
            entry["id"]: entry
            for entry in [plan, self_fetch, search, chapter_fetch, pre_fetch, mutation]
        }
        approval = VERIFIER.normalized_approval_message(self.plan)
        plan_arguments = json.loads(plan["argumentsJSON"])
        pre_arguments = json.loads(pre_fetch["argumentsJSON"])
        turns = [
            self.turn("turn-plan-source", self.tool_call("present_course_plan", plan_arguments)),
            self.turn(
                "turn-plan-result",
                self.tool_result(by_id["call-plan"]),
                self.agent_text("The plan is ready for review."),
            ),
            self.turn(
                "turn-approval",
                self.user_text(approval, "approval-message"),
                self.tool_call("native-editor-fetch", self_arguments),
            ),
            self.turn(
                "turn-fetch-self-result",
                self.tool_result(by_id["call-fetch-self"]),
                self.tool_call("native-editor-search", search_arguments),
            ),
            self.turn(
                "turn-search-result",
                self.tool_result(by_id["call-search"]),
                self.tool_call("native-editor-fetch", chapter_arguments),
            ),
            self.turn(
                "turn-fetch-chapter-result",
                self.tool_result(by_id["call-fetch-chapter"]),
                self.tool_call("native-editor-fetch", pre_arguments),
            ),
            self.turn(
                "turn-fetch-before-result",
                self.tool_result(by_id["call-fetch-before"]),
                self.tool_call("native-editor-update-page", mutation_arguments),
            ),
            self.turn(
                "turn-update-result",
                self.tool_result(by_id["call-update"]),
                self.agent_text("Done — the phone result was returned and the lesson is verified."),
            ),
        ]
        self.write_json(
            self.bridge_state / "turns.json",
            {"threads": {self.thread_id: turns}, "activeRuns": {}, "submissionIntents": {}},
        )
        self.refresh_manifest()

        summary = self.verify()

        self.assertEqual(summary["status"], "artifact_consistency_verified")
        self.assertEqual(summary["tool_calls"], 6)
        self.assertEqual(summary["lesson_revision_after"], 2)

    def test_rejects_ambiguous_update_content_old_str(self):
        entries = self.read_json(self.course_dir / "remote-hermes-tool-journal.json")
        mutation_arguments = json.loads(entries[2]["argumentsJSON"])
        mutation_arguments.pop("new_str")
        mutation_arguments["command"] = "update_content"
        mutation_arguments["content_updates"] = [
            {"old_str": "o", "new_str": self.mutation_markdown}
        ]
        entries[2]["argumentsJSON"] = compact(mutation_arguments)
        self.write_json(self.course_dir / "remote-hermes-tool-journal.json", entries)
        self.refresh_manifest()

        with self.assertRaisesRegex(VERIFIER.EvidenceError, "occur exactly once"):
            self.verify()

    def test_final_swift_example_typechecks(self):
        VERIFIER.verify_swift_example(self.final_markdown, typecheck=True)

    def test_rejects_native_document_content_mismatch(self):
        database_path = self.course_dir / "course-library.sqlite"
        database = sqlite3.connect(database_path)
        row = database.execute(
            "SELECT document_json FROM page_documents WHERE page_id = ?", (self.page_id,)
        ).fetchone()
        document = json.loads(row[0])
        document["document"]["children"][1]["data"]["delta"][0]["insert"] = "Different native content."
        encoded = compact(document).encode()
        database.execute(
            "UPDATE page_documents SET document_json = ?, checksum = ? WHERE page_id = ?",
            (encoded, hashlib.sha256(encoded).hexdigest(), self.page_id),
        )
        database.commit()
        database.close()
        self.refresh_manifest()
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "native document content differs"):
            self.verify()

    def test_rejects_database_checksum_mismatch(self):
        database = sqlite3.connect(self.course_dir / "course-library.sqlite")
        database.execute("UPDATE page_documents SET checksum = 'bad' WHERE page_id = ?", (self.page_id,))
        database.commit()
        database.close()
        self.refresh_manifest()
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "checksum mismatch"):
            self.verify()

    def test_rejects_wrong_database_schema_version(self):
        database = sqlite3.connect(self.course_dir / "course-library.sqlite")
        database.execute("PRAGMA user_version = 2")
        database.close()
        self.refresh_manifest()
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "schema version"):
            self.verify()

    def test_rejects_non_integer_sqlite_revision(self):
        database = sqlite3.connect(self.course_dir / "course-library.sqlite")
        database.execute(
            "UPDATE page_documents SET revision = 2.5 WHERE page_id = ?",
            (self.page_id,),
        )
        database.commit()
        database.close()
        self.refresh_manifest()
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "not stored as an integer"):
            self.verify()

    def test_rejects_wal_without_shm(self):
        database_path = self.course_dir / "course-library.sqlite"
        Path(f"{database_path}-wal").write_bytes(b"unpaired-wal")
        Path(f"{database_path}-shm").unlink(missing_ok=True)
        self.refresh_manifest()
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "WAL and SHM"):
            self.verify()

    def test_rejects_extra_unjournaled_tool_call(self):
        def add_extra(root):
            root["threads"][self.thread_id].append(
                self.turn(
                    "turn-extra",
                    self.tool_call(
                        "native-editor-fetch",
                        {"workspace_id": self.workspace_id, "id": self.page_id},
                    ),
                )
            )

        self.mutate_json(self.bridge_state / "turns.json", add_extra)
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "unjournaled tool calls"):
            self.verify()

    def test_rejects_extra_unjournaled_tool_result(self):
        def add_extra(root):
            fake = {
                "id": "extra",
                "toolName": "native-editor-fetch",
                "output": "{}",
                "sourceTurnID": "turn-extra-source",
            }
            root["threads"][self.thread_id].append(self.turn("turn-extra-result", self.tool_result(fake)))

        self.mutate_json(self.bridge_state / "turns.json", add_extra)
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "unjournaled tool results"):
            self.verify()

    def test_rejects_broken_editor_adjacency(self):
        def break_link(entries):
            entries[2]["sourceTurnID"] = "disconnected-turn"

        self.mutate_json(self.course_dir / "remote-hermes-tool-journal.json", break_link)
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "linkage is broken"):
            self.verify()

    def test_rejects_non_contiguous_or_boolean_chain_steps(self):
        def break_step(entries):
            entries[2]["chainStep"] = True

        self.mutate_json(self.course_dir / "remote-hermes-tool-journal.json", break_step)
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "invalid chain step"):
            self.verify()

    def test_rejects_boolean_manifest_schema(self):
        manifest = self.read_json(self.manifest_path)
        manifest["schema_version"] = True
        self.write_json(self.manifest_path, manifest)
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "run-manifest schema"):
            self.verify()

    def test_rejects_missing_signing_evidence(self):
        manifest = self.read_json(self.manifest_path)
        manifest["artifacts"].pop("signing_info_raw")
        self.write_json(self.manifest_path, manifest)
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "missing signing_info_raw evidence"):
            self.verify()

    def test_rejects_signing_team_not_present_in_raw_codesign_output(self):
        raw_path = self.capture_dir / "signing-info.raw.txt"
        raw_path.write_text(raw_path.read_text().replace("TeamIdentifier=UF4L3PL7UG", "TeamIdentifier=OTHERTEAM"))
        signing_info_path = self.capture_dir / "signing-info.json"
        signing_info = self.read_json(signing_info_path)
        signing_info["raw_sha256"] = hashlib.sha256(raw_path.read_bytes()).hexdigest()
        self.write_json(signing_info_path, signing_info)
        self.refresh_manifest()
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "missing TeamIdentifier=UF4L3PL7UG"):
            self.verify()

    def test_rejects_float_plan_revision(self):
        def change_plan(plan):
            plan["revision"] = 1.0

        self.mutate_json(self.course_dir / "approved-plan.json", change_plan)
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "plan revision"):
            self.verify()

    def test_rejects_plan_approval_mismatch(self):
        def change_plan(plan):
            plan["revision"] = 2

        self.mutate_json(self.course_dir / "approved-plan.json", change_plan)
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "does not exactly match"):
            self.verify()

    def test_rejects_missing_exact_learner_approval(self):
        def remove_approval(root):
            approval_turn = root["threads"][self.thread_id][2]
            approval_turn["items"] = approval_turn["items"][1:]

        self.mutate_json(self.bridge_state / "turns.json", remove_approval)
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "deterministic learner approval"):
            self.verify()

    def test_rejects_negated_quoted_approval(self):
        def negate_approval(root):
            approval_text = root["threads"][self.thread_id][2]["items"][0]["content"][0]["text"]
            root["threads"][self.thread_id][2]["items"][0]["content"][0]["text"] = (
                "I do not approve. Quoted text: " + approval_text
            )

        self.mutate_json(self.bridge_state / "turns.json", negate_approval)
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "deterministic learner approval"):
            self.verify()

    def test_rejects_missing_final_assistant_response(self):
        def remove_final(root):
            root["threads"][self.thread_id][-1]["items"] = root["threads"][self.thread_id][-1]["items"][:1]

        self.mutate_json(self.bridge_state / "turns.json", remove_final)
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "learner-facing Hermes response"):
            self.verify()

    def test_rejects_pending_remote_run(self):
        def add_pending(root):
            root["activeRuns"][self.thread_id] = {"runId": "run-active"}

        self.mutate_json(self.bridge_state / "turns.json", add_pending)
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "remains in activeRuns"):
            self.verify()

    def test_rejects_pending_submission_intent(self):
        def add_pending(root):
            root["submissionIntents"][self.thread_id] = {"submissionId": "intent-active"}

        self.mutate_json(self.bridge_state / "turns.json", add_pending)
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "remains in submissionIntents"):
            self.verify()

    def test_rejects_result_not_executed_on_mobile_device(self):
        def change_result(root):
            text_part = root["threads"][self.thread_id][-1]["items"][0]["content"][0]
            envelope, continuation = text_part["text"].split("\n\n", 1)
            payload = json.loads(envelope)
            payload["learnfold_tool_result"]["executed_on"] = "vps"
            text_part["text"] = compact(payload) + "\n\n" + continuation

        self.mutate_json(self.bridge_state / "turns.json", change_result)
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "executed_on"):
            self.verify()

    def test_rejects_missing_submissions_journal(self):
        (self.course_dir / "remote-hermes-submissions.json").unlink()
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "missing evidence path"):
            self.verify()

    def test_rejects_pending_phone_submission(self):
        self.write_json(
            self.course_dir / "remote-hermes-submissions.json",
            [{"workspaceID": self.workspace_id, "threadID": self.thread_id}],
        )
        self.refresh_manifest()
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "pending phone submission"):
            self.verify()

    def test_rejects_wrong_model_or_binding_policy(self):
        def change_binding(root):
            root["bindings"][0]["model"] = "another-model"

        self.mutate_json(self.bridge_state / "threads.json", change_binding)
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "exact expected Hermes model"):
            self.verify()

    def test_rejects_wrong_device_owned_cwd(self):
        def change_binding(root):
            root["bindings"][0]["cwd"] = "/tmp/workspace-proof"

        self.mutate_json(self.bridge_state / "threads.json", change_binding)
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "device-owned sentinel"):
            self.verify()

    def test_rejects_boolean_attempt_count(self):
        def break_attempt(entries):
            entries[0]["resultSubmissionAttempts"] = True

        self.mutate_json(self.course_dir / "remote-hermes-tool-journal.json", break_attempt)
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "result-submission attempt"):
            self.verify()

    def test_rejects_tool_call_with_trailing_prose(self):
        def add_prose(root):
            item = root["threads"][self.thread_id][0]["items"][0]
            item["text"] += "\nI also called the tool."

        self.mutate_json(self.bridge_state / "turns.json", add_prose)
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "non-exact tool-call envelope"):
            self.verify()

    def test_rejects_plan_result_without_pending_approval_status(self):
        def change_result(root):
            text_part = root["threads"][self.thread_id][1]["items"][0]["content"][0]
            envelope, continuation = text_part["text"].split("\n\n", 1)
            payload = json.loads(envelope)
            del payload["learnfold_tool_result"]["approval_status"]
            text_part["text"] = compact(payload) + "\n\n" + continuation

        self.mutate_json(self.bridge_state / "turns.json", change_result)
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "not approval-gated"):
            self.verify()

    def test_rejects_non_terminal_native_course(self):
        database = sqlite3.connect(self.course_dir / "course-library.sqlite")
        row = database.execute(
            "SELECT document_json FROM page_documents WHERE page_id = ?",
            (self.native_fixture["rootPageID"],),
        ).fetchone()
        document = json.loads(row[0])
        document["document"]["data"]["course_bootstrap_status"] = "building"
        encoded = compact(document).encode()
        database.execute(
            "UPDATE page_documents SET document_json = ?, checksum = ? WHERE page_id = ?",
            (encoded, hashlib.sha256(encoded).hexdigest(), self.native_fixture["rootPageID"]),
        )
        database.commit()
        database.close()
        self.refresh_manifest()
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "not ready for learning"):
            self.verify()

    def test_rejects_missing_context_page(self):
        context_id = self.native_fixture["contextPageIDs"][0]
        database = sqlite3.connect(self.course_dir / "course-library.sqlite")
        database.execute("DELETE FROM page_documents WHERE page_id = ?", (context_id,))
        database.execute("DELETE FROM library_items WHERE id = ?", (context_id,))
        database.commit()
        database.close()
        self.refresh_manifest()
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "three context pages"):
            self.verify()

    def test_rejects_missing_preimage_history(self):
        database = sqlite3.connect(self.course_dir / "course-library.sqlite")
        database.execute("DELETE FROM page_history WHERE page_id = ?", (self.page_id,))
        database.commit()
        database.close()
        self.refresh_manifest()
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "preimage history"):
            self.verify()

    def test_accepts_multiple_transient_sync_receipts(self):
        database = sqlite3.connect(self.course_dir / "course-library.sqlite")
        database.executemany(
            "INSERT INTO sync_mutation_receipts("
            "id, changed_page_ids_json, deleted_item_ids_json, requires_full_inventory, created_at"
            ") VALUES (?, ?, '[]', 1, ?)",
            [
                ("transient-one", compact([self.page_id]), 1),
                ("transient-two", compact([self.native_fixture["rootPageID"]]), 2),
            ],
        )
        database.commit()
        database.close()
        self.refresh_manifest()
        self.assertEqual(self.verify()["status"], "artifact_consistency_verified")

    def test_rejects_foreign_key_violation(self):
        database = sqlite3.connect(self.course_dir / "course-library.sqlite")
        database.execute(
            "INSERT INTO page_history(id, page_id, document_json, created_at, label) VALUES (?, ?, ?, 1, NULL)",
            ("orphan-history", "missing-page", b"{}"),
        )
        database.commit()
        database.close()
        self.refresh_manifest()
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "foreign-key check"):
            self.verify()

    def test_rejects_magic_bytes_without_decodable_video(self):
        (self.capture_dir / "lifecycle.mp4").write_bytes(
            b"\x00\x00\x00\x18ftypisomnot-a-real-recording"
        )
        self.refresh_manifest()
        with self.assertRaisesRegex(VERIFIER.EvidenceError, "cannot be decoded"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
