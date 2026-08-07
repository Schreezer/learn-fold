#!/usr/bin/env python3
"""Fail-closed consistency audit for a captured Hermes iPhone lifecycle run.

This tool joins a fresh iPhone course export, a point-in-time Kittylitter state
snapshot, and a capture manifest. A pass proves that those captured artifacts
are mutually consistent. It does not authenticate their origin; a trusted
reviewer must inspect raw device, signing, media, and app-log evidence before
making a physical-device or background-execution claim.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from collections.abc import Iterable
from datetime import datetime
from pathlib import Path
from typing import Any


MUTATING_TOOLS = {
    "native-editor-create-pages",
    "native-editor-duplicate-page",
    "native-editor-move-pages",
    "native-editor-update-page",
}
ALLOWED_PROOF_TOOLS = {
    "present_course_plan",
    "native-editor-fetch",
    "native-editor-search",
    "native-editor-update-page",
}
PLAN_CONTINUATION = (
    "Tell the learner the plan is ready for review, then wait. Do not call another "
    "course tool until the learner approves or requests a revision."
)
TOOL_CONTINUATION = (
    "Continue the course task. Return either one learnfold_tool_call JSON object or "
    "a normal learner-facing response."
)
REQUIRED_PAGE_COLUMNS = {
    "page_id",
    "document_json",
    "plain_text",
    "revision",
    "checksum",
    "updated_at",
}
REQUIRED_DATABASE_OBJECTS = {
    "library_items",
    "metadata",
    "page_documents",
    "page_history",
    "page_search",
    "sync_mutation_receipts",
}


class EvidenceError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)


def is_strict_int(value: Any) -> bool:
    return type(value) is int


def absolute_without_resolving(path: Path) -> Path:
    return Path(os.path.abspath(os.fspath(path)))


def require_safe_path(path: Path, evidence_root: Path, *, file: bool = True) -> Path:
    root = absolute_without_resolving(evidence_root)
    candidate = absolute_without_resolving(path)
    require(not root.is_symlink(), f"evidence root must not be a symlink: {root}")
    require(candidate.is_relative_to(root), f"evidence path escapes capture root: {candidate}")
    current = root
    for component in candidate.relative_to(root).parts:
        current /= component
        require(not current.is_symlink(), f"symlinked evidence path is not accepted: {current}")
    require(candidate.is_file() if file else candidate.is_dir(), f"missing evidence path: {candidate}")
    return candidate


def stable_bytes(path: Path, evidence_root: Path) -> bytes:
    path = require_safe_path(path, evidence_root)
    before = path.stat()
    try:
        data = path.read_bytes()
    except OSError as error:
        raise EvidenceError(f"could not read evidence at {path}: {error}") from error
    after = path.stat()
    require(
        (before.st_ino, before.st_size, before.st_mtime_ns)
        == (after.st_ino, after.st_size, after.st_mtime_ns),
        f"evidence changed while being read: {path}",
    )
    return data


def load_json(path: Path, evidence_root: Path) -> Any:
    try:
        return json.loads(stable_bytes(path, evidence_root))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"invalid JSON evidence at {path}: {error}") from error


def sha256_file(path: Path, evidence_root: Path) -> str:
    return hashlib.sha256(stable_bytes(path, evidence_root)).hexdigest()


def parse_embedded_json(value: Any, label: str) -> dict[str, Any]:
    require(isinstance(value, str) and value, f"{label} must be a non-empty JSON string")
    try:
        decoded = json.loads(value)
    except json.JSONDecodeError as error:
        raise EvidenceError(f"{label} is not valid JSON: {error}") from error
    require(isinstance(decoded, dict), f"{label} must decode to an object")
    return decoded


def item_texts(turn: dict[str, Any], item_type: str) -> Iterable[str]:
    items = turn.get("items")
    require(isinstance(items, list), f"turn {turn.get('id')} items must be an array")
    for item in items:
        require(isinstance(item, dict), f"turn {turn.get('id')} contains a malformed item")
        if item.get("type") != item_type:
            continue
        if item_type == "agentMessage":
            text = item.get("text")
            require(isinstance(text, str), f"turn {turn.get('id')} agent text must be a string")
            yield text
            continue
        content = item.get("content")
        require(isinstance(content, list), f"turn {turn.get('id')} user content must be an array")
        for part in content:
            require(isinstance(part, dict), f"turn {turn.get('id')} has malformed user content")
            text = part.get("text")
            if text is not None:
                require(isinstance(text, str), f"turn {turn.get('id')} user text must be a string")
                yield text


def exact_tool_call(text: str, turn_id: str) -> dict[str, Any] | None:
    marker = "learnfold_tool_call"
    if marker not in text:
        return None
    try:
        root = json.loads(text.strip())
    except json.JSONDecodeError as error:
        raise EvidenceError(f"turn {turn_id} contains a non-exact tool-call envelope: {error}") from error
    require(isinstance(root, dict) and set(root) == {marker}, f"turn {turn_id} tool call must be one bare envelope")
    call = root[marker]
    require(isinstance(call, dict) and set(call) == {"name", "arguments"}, f"turn {turn_id} has malformed tool call")
    require(isinstance(call["name"], str) and call["name"], f"turn {turn_id} tool name is invalid")
    require(isinstance(call["arguments"], dict), f"turn {turn_id} tool arguments must be an object")
    return call


def exact_tool_result(text: str, turn_id: str) -> dict[str, Any] | None:
    marker = "learnfold_tool_result"
    if marker not in text:
        return None
    parts = text.strip().split("\n\n", 1)
    require(len(parts) == 2, f"turn {turn_id} tool result is missing its continuation contract")
    try:
        root = json.loads(parts[0])
    except json.JSONDecodeError as error:
        raise EvidenceError(f"turn {turn_id} contains a malformed tool-result envelope: {error}") from error
    require(isinstance(root, dict) and set(root) == {marker}, f"turn {turn_id} result must begin with one bare envelope")
    result = root[marker]
    require(isinstance(result, dict), f"turn {turn_id} tool result must be an object")
    expected_continuation = PLAN_CONTINUATION if result.get("name") == "present_course_plan" else TOOL_CONTINUATION
    require(parts[1].strip() == expected_continuation, f"turn {turn_id} tool-result continuation mismatch")
    return result


def parse_iso8601(value: Any, label: str) -> datetime:
    require(isinstance(value, str) and value, f"manifest {label} must be an ISO-8601 string")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise EvidenceError(f"manifest {label} is not ISO-8601: {error}") from error
    require(parsed.tzinfo is not None, f"manifest {label} must include a timezone")
    return parsed


def verify_manifest(
    manifest_path: Path,
    workspace: Path,
    bridge_state: Path,
    expected_model: str,
    expected_bundle_id: str,
    ffprobe: Path | None,
) -> tuple[dict[str, Any], Path]:
    evidence_root = absolute_without_resolving(manifest_path.parent)
    manifest_path = require_safe_path(manifest_path, evidence_root)
    workspace = require_safe_path(workspace, evidence_root, file=False)
    bridge_state = require_safe_path(bridge_state, evidence_root, file=False)
    manifest = load_json(manifest_path, evidence_root)
    require(isinstance(manifest, dict), "run manifest must be an object")
    require(is_strict_int(manifest.get("schema_version")) and manifest["schema_version"] == 1, "unsupported run-manifest schema")
    require(manifest.get("fresh_workspace") is True, "proof must use a fresh workspace")
    require(manifest.get("workspace_id") == workspace.name, "manifest workspace mismatch")
    require(manifest.get("expected_model") == expected_model, "manifest model expectation mismatch")

    device = manifest.get("device")
    app = manifest.get("app")
    lifecycle = manifest.get("lifecycle")
    require(isinstance(device, dict), "manifest device record is missing")
    require(device.get("reality") == "physical", "manifest does not describe a physical device")
    for field in ("name", "udid", "model", "os_version", "os_build"):
        require(isinstance(device.get(field), str) and device[field], f"manifest device.{field} is missing")
    require(isinstance(app, dict), "manifest app record is missing")
    require(app.get("bundle_id") == expected_bundle_id, "manifest app bundle mismatch")
    require(app.get("signed") is True, "manifest does not attest a signed app")
    for field in ("team_id", "version", "build"):
        require(isinstance(app.get(field), str) and app[field], f"manifest app.{field} is missing")
    require(isinstance(lifecycle, dict), "manifest lifecycle record is missing")
    timestamps = [
        parse_iso8601(lifecycle.get(field), f"lifecycle.{field}")
        for field in ("recording_started_at", "backgrounded_at", "foregrounded_at", "completed_at")
    ]
    require(timestamps == sorted(timestamps) and len(set(timestamps)) == 4, "lifecycle timestamps are not strictly ordered")

    expected_artifacts = {
        "tool_journal": workspace / ".course/remote-hermes-tool-journal.json",
        "submissions": workspace / ".course/remote-hermes-submissions.json",
        "approved_plan": workspace / ".course/approved-plan.json",
        "course_database": workspace / ".course/course-library.sqlite",
        "turns": bridge_state / "turns.json",
        "threads": bridge_state / "threads.json",
    }
    database_wal = workspace / ".course/course-library.sqlite-wal"
    database_shm = workspace / ".course/course-library.sqlite-shm"
    if database_wal.exists():
        expected_artifacts["course_database_wal"] = database_wal
    if database_shm.exists():
        expected_artifacts["course_database_shm"] = database_shm
    artifacts = manifest.get("artifacts")
    require(isinstance(artifacts, dict), "manifest artifacts record is missing")
    for key in (
        "screen_record",
        "final_screenshot",
        "device_info",
        "app_info",
        "device_info_raw",
        "app_info_raw",
        "signing_info",
        "signing_info_raw",
    ):
        require(key in artifacts, f"manifest is missing {key} evidence")
    for key, expected_path in expected_artifacts.items():
        require(key in artifacts, f"manifest is missing {key} evidence")
        record = artifacts[key]
        require(isinstance(record, dict), f"manifest artifact {key} must be an object")
        raw_path = record.get("path")
        require(isinstance(raw_path, str) and raw_path, f"manifest artifact {key} has no path")
        actual_path = require_safe_path(evidence_root / raw_path, evidence_root)
        require(actual_path == absolute_without_resolving(expected_path), f"manifest artifact {key} points to the wrong file")
        require(record.get("sha256") == sha256_file(actual_path, evidence_root), f"manifest artifact {key} hash mismatch")
    capture_paths: dict[str, Path] = {}
    for key in (
        "screen_record",
        "final_screenshot",
        "device_info",
        "app_info",
        "device_info_raw",
        "app_info_raw",
        "signing_info",
        "signing_info_raw",
    ):
        record = artifacts[key]
        require(isinstance(record, dict), f"manifest artifact {key} must be an object")
        raw_path = record.get("path")
        require(isinstance(raw_path, str) and raw_path, f"manifest artifact {key} has no path")
        path = require_safe_path(evidence_root / raw_path, evidence_root)
        capture_paths[key] = path
        require(record.get("sha256") == sha256_file(path, evidence_root), f"manifest artifact {key} hash mismatch")
    screen_record = stable_bytes(capture_paths["screen_record"], evidence_root)
    final_screenshot = stable_bytes(capture_paths["final_screenshot"], evidence_root)
    require(len(screen_record) >= 12 and screen_record[4:8] == b"ftyp", "screen_record is not an MP4 capture")
    require(final_screenshot.startswith(b"\x89PNG\r\n\x1a\n"), "final_screenshot is not a PNG capture")
    ffprobe_path = absolute_without_resolving(ffprobe) if ffprobe is not None else None
    if ffprobe_path is None:
        discovered_ffprobe = shutil.which("ffprobe")
        ffprobe_path = Path(discovered_ffprobe) if discovered_ffprobe else None
    require(ffprobe_path is not None and ffprobe_path.is_file(), "ffprobe is required to validate the screen recording")
    media_result = subprocess.run(
        [
            os.fspath(ffprobe_path),
            "-v",
            "error",
            "-show_entries",
            "format=duration:stream=codec_type,width,height",
            "-of",
            "json",
            os.fspath(capture_paths["screen_record"]),
        ],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    require(media_result.returncode == 0, f"screen_record cannot be decoded: {media_result.stderr.strip()}")
    try:
        media = json.loads(media_result.stdout)
        duration = float(media["format"]["duration"])
        video_streams = [stream for stream in media["streams"] if stream.get("codec_type") == "video"]
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        raise EvidenceError(f"screen_record metadata is invalid: {error}") from error
    require(duration >= 1.0, "screen_record is too short to contain lifecycle evidence")
    require(
        len(video_streams) == 1
        and is_strict_int(video_streams[0].get("width"))
        and video_streams[0]["width"] > 0
        and is_strict_int(video_streams[0].get("height"))
        and video_streams[0]["height"] > 0,
        "screen_record has no decodable video dimensions",
    )
    image_result = subprocess.run(
        ["/usr/bin/sips", "-g", "pixelWidth", "-g", "pixelHeight", os.fspath(capture_paths["final_screenshot"])],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    require(image_result.returncode == 0, f"final_screenshot cannot be decoded: {image_result.stderr.strip()}")
    require(
        re.search(r"pixelWidth:\s*[1-9][0-9]*", image_result.stdout) is not None
        and re.search(r"pixelHeight:\s*[1-9][0-9]*", image_result.stdout) is not None,
        "final_screenshot has no decodable image dimensions",
    )
    device_info = load_json(capture_paths["device_info"], evidence_root)
    app_info = load_json(capture_paths["app_info"], evidence_root)
    signing_info = load_json(capture_paths["signing_info"], evidence_root)
    require(isinstance(device_info, dict), "device_info evidence must be JSON")
    require(isinstance(app_info, dict), "app_info evidence must be JSON")
    require(isinstance(signing_info, dict), "signing_info evidence must be JSON")
    require(stable_bytes(capture_paths["device_info_raw"], evidence_root), "raw device-info evidence is empty")
    require(stable_bytes(capture_paths["app_info_raw"], evidence_root), "raw app-info evidence is empty")
    signing_raw_bytes = stable_bytes(capture_paths["signing_info_raw"], evidence_root)
    require(signing_raw_bytes, "raw signing evidence is empty")
    require(device_info.get("source") == "xcrun devicectl device info details", "device_info source is not devicectl")
    require(app_info.get("source") == "xcrun devicectl device info apps", "app_info source is not devicectl")
    require(
        signing_info.get("source") == "codesign -vv --strict; codesign -dvvv; Info.plist",
        "signing_info source is not the required codesign capture",
    )
    require(
        device_info.get("raw_sha256") == sha256_file(capture_paths["device_info_raw"], evidence_root),
        "normalized device_info is not bound to its raw CoreDevice output",
    )
    require(
        app_info.get("raw_sha256") == sha256_file(capture_paths["app_info_raw"], evidence_root),
        "normalized app_info is not bound to its raw CoreDevice output",
    )
    require(
        signing_info.get("raw_sha256") == sha256_file(capture_paths["signing_info_raw"], evidence_root),
        "normalized signing_info is not bound to its raw codesign output",
    )
    for field in ("reality", "name", "udid", "model", "os_version", "os_build"):
        require(device_info.get(field) == device[field], f"device_info {field} does not match the manifest")
    for field in ("bundle_id", "signed", "team_id", "version", "build"):
        require(app_info.get(field) == app[field], f"app_info {field} does not match the manifest")
    require(app_info.get("device_udid") == device["udid"], "app_info is not bound to the proof device")
    for field in ("bundle_id", "team_id", "version", "build"):
        require(signing_info.get(field) == app[field], f"signing_info {field} does not match the manifest")
    cdhash = signing_info.get("cdhash")
    authority = signing_info.get("authority")
    require(isinstance(cdhash, str) and re.fullmatch(r"[0-9a-f]{40}", cdhash) is not None, "signing_info CDHash is invalid")
    require(isinstance(authority, str) and authority.startswith("Apple Development:"), "signing_info authority is invalid")
    try:
        signing_raw = signing_raw_bytes.decode("utf-8")
    except UnicodeDecodeError as error:
        raise EvidenceError(f"raw signing evidence is not UTF-8: {error}") from error
    for marker in (
        "valid on disk",
        "satisfies its Designated Requirement",
        f"Identifier={app['bundle_id']}",
        f"TeamIdentifier={app['team_id']}",
        f"CDHash={cdhash}",
        f"Authority={authority}",
        f"CFBundleIdentifier={app['bundle_id']}",
        f"CFBundleShortVersionString={app['version']}",
        f"CFBundleVersion={app['build']}",
    ):
        require(marker in signing_raw, f"raw signing evidence is missing {marker}")
    return manifest, evidence_root


def sqlite_snapshot(
    database_path: Path,
    evidence_root: Path,
) -> tuple[tempfile.TemporaryDirectory[str], Path, sqlite3.Connection]:
    wal_path = Path(f"{database_path}-wal")
    shm_path = Path(f"{database_path}-shm")
    require(wal_path.exists() == shm_path.exists(), "captured SQLite WAL and SHM must be present as a pair")
    temporary_directory = tempfile.TemporaryDirectory(prefix="learnfold-sqlite-proof-")
    try:
        copy_path = Path(temporary_directory.name) / database_path.name
        copy_path.write_bytes(stable_bytes(database_path, evidence_root))
        for source_path in (wal_path, shm_path):
            if source_path.exists():
                destination = Path(f"{copy_path}{source_path.name.removeprefix(database_path.name)}")
                destination.write_bytes(stable_bytes(source_path, evidence_root))
        try:
            source = sqlite3.connect(f"{copy_path.as_uri()}?mode=ro", uri=True)
            snapshot = sqlite3.connect(":memory:")
            source.backup(snapshot)
            source.close()
        except sqlite3.Error as error:
            raise EvidenceError(f"could not snapshot course database: {error}") from error
    except Exception:
        temporary_directory.cleanup()
        raise
    return temporary_directory, copy_path, snapshot


def native_inspection(native_helper: Path, database_path: Path, page_id: str) -> dict[str, Any]:
    helper = absolute_without_resolving(native_helper)
    require(helper.is_file() and not helper.is_symlink(), f"native evidence helper is missing or symlinked: {helper}")
    require(os.access(helper, os.X_OK), f"native evidence helper is not executable: {helper}")
    result = subprocess.run(
        [os.fspath(helper), "inspect", os.fspath(database_path), page_id],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    require(result.returncode == 0, f"native evidence helper failed: {result.stderr.strip()}")
    try:
        inspection = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise EvidenceError(f"native evidence helper returned invalid JSON: {error}") from error
    require(isinstance(inspection, dict), "native evidence helper result must be an object")
    require(
        set(inspection)
        == {
            "pageID",
            "revision",
            "markdown",
            "plainText",
            "documentSHA256",
            "historyMarkdown",
        },
        "native evidence helper returned an unexpected schema",
    )
    return inspection


def verify_swift_example(markdown: str, *, typecheck: bool) -> None:
    matches = re.findall(r"```swift\n(.*?)\n```", markdown, flags=re.DOTALL)
    require(len(matches) == 1, "final lesson must contain exactly one Swift fenced code block")
    require(re.search(r"\bexercise\b", markdown, flags=re.IGNORECASE) is not None, "final lesson has no identifiable exercise")
    require(len(re.findall(r"\b[\w'-]+\b", markdown)) <= 120, "final lesson exceeds the 120-word approval contract")
    if not typecheck:
        return
    with tempfile.TemporaryDirectory(prefix="learnfold-swift-proof-") as temporary_directory:
        source_path = Path(temporary_directory) / "Proof.swift"
        source_path.write_text(matches[0], encoding="utf-8")
        result = subprocess.run(
            ["xcrun", "swiftc", "-typecheck", os.fspath(source_path)],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
    require(result.returncode == 0, f"final Swift example does not typecheck: {result.stderr.strip()}")


def normalized_approval_message(plan: dict[str, Any]) -> str:
    chapters = plan.get("chapters")
    require(isinstance(chapters, list) and chapters, "approved plan has no Chapter 1")
    first_chapter = chapters[0]
    require(isinstance(first_chapter, dict), "approved plan Chapter 1 is malformed")
    chapter_title = first_chapter.get("title")
    require(isinstance(chapter_title, str) and chapter_title, "approved plan Chapter 1 has no title")
    message = (
        f"I approve course plan {plan.get('plan_id')}, revision {plan.get('revision')}. "
        "Learnfold has already created the learner context pages, every chapter folder, and one "
        f"pending lesson page for Chapter 1 ({chapter_title}). "
        "Use native-editor-fetch to inspect that pending lesson, then native-editor-update-page "
        "to update only that page with a concise, complete beginner lesson of at most 120 words: "
        "explanation, one small compiling Swift example, and one short exercise. Set its "
        "generation_status to generated in that same update. Do not create or edit later chapter "
        "lessons, and do not recreate the course structure."
    )
    return re.sub(r"\s+", " ", message).strip()


def verify_workspace(
    workspace: Path,
    bridge_state: Path,
    manifest_path: Path,
    expected_model: str,
    expected_bundle_id: str,
    native_helper: Path,
    *,
    typecheck_swift: bool = True,
    ffprobe: Path | None = None,
) -> dict[str, Any]:
    require(isinstance(expected_model, str) and expected_model, "expected model must be non-empty")
    require(isinstance(expected_bundle_id, str) and expected_bundle_id, "expected bundle ID must be non-empty")
    manifest, evidence_root = verify_manifest(
        manifest_path,
        workspace,
        bridge_state,
        expected_model,
        expected_bundle_id,
        ffprobe,
    )
    workspace = absolute_without_resolving(workspace)
    bridge_state = absolute_without_resolving(bridge_state)
    workspace_id = workspace.name
    course_dir = workspace / ".course"
    journal_path = course_dir / "remote-hermes-tool-journal.json"
    submissions_path = course_dir / "remote-hermes-submissions.json"
    approved_plan_path = course_dir / "approved-plan.json"
    database_path = course_dir / "course-library.sqlite"
    turns_path = bridge_state / "turns.json"
    threads_path = bridge_state / "threads.json"

    journal = load_json(journal_path, evidence_root)
    require(isinstance(journal, list) and journal, "tool journal must be a non-empty array")
    require(all(isinstance(entry, dict) for entry in journal), "tool journal entries must be objects")
    entries: list[dict[str, Any]] = list(journal)
    call_ids: set[str] = set()
    source_turn_ids: set[str] = set()
    result_turn_ids: set[str] = set()
    thread_ids: set[str] = set()
    for index, entry in enumerate(entries):
        label = f"tool journal entry {index}"
        for field in ("id", "threadID", "sourceTurnID", "resultTurnID", "toolName", "chainRootTurnID"):
            require(isinstance(entry.get(field), str) and entry[field], f"{label} missing {field}")
        require(entry.get("workspaceID") == workspace_id, f"{label} workspace mismatch")
        require(entry["toolName"] in ALLOWED_PROOF_TOOLS, f"{label} uses an unexpected proof tool")
        require(entry.get("phase") == "completed", f"{label} is not completed")
        require(entry.get("success") is True, f"{label} did not succeed")
        attempts = entry.get("resultSubmissionAttempts")
        require(is_strict_int(attempts) and attempts >= 1, f"{label} has no durable result-submission attempt")
        require(entry["id"] not in call_ids, f"duplicate tool call id {entry['id']}")
        require(entry["sourceTurnID"] not in source_turn_ids, f"duplicate source turn {entry['sourceTurnID']}")
        require(entry["resultTurnID"] not in result_turn_ids, f"duplicate result turn {entry['resultTurnID']}")
        call_ids.add(entry["id"])
        source_turn_ids.add(entry["sourceTurnID"])
        result_turn_ids.add(entry["resultTurnID"])
        thread_ids.add(entry["threadID"])
        arguments = parse_embedded_json(entry.get("argumentsJSON"), f"{label} argumentsJSON")
        require(arguments.get("workspace_id") == workspace_id, f"{label} argument workspace mismatch")
        require(isinstance(entry.get("output"), str), f"{label} is missing its local result output")
        if entry["toolName"].startswith("native-editor-"):
            parse_embedded_json(entry["output"], f"{label} output")
    require(len(thread_ids) == 1, "workspace evidence spans multiple Hermes threads")
    thread_id = next(iter(thread_ids))

    present_entries = [entry for entry in entries if entry["toolName"] == "present_course_plan"]
    require(len(present_entries) == 1, "fresh proof must contain exactly one completed plan presentation")
    present = present_entries[0]
    require(is_strict_int(present.get("chainStep")) and present["chainStep"] == 1, "plan presentation has an invalid chain step")
    require(present["chainRootTurnID"] == present["sourceTurnID"], "plan chain root is not its source turn")
    approved_plan = load_json(approved_plan_path, evidence_root)
    require(isinstance(approved_plan, dict), "approved plan must be an object")
    require(is_strict_int(approved_plan.get("revision")) and approved_plan["revision"] >= 1, "approved plan revision must be a positive integer")
    plan_arguments = parse_embedded_json(present["argumentsJSON"], "presented plan arguments")
    require(
        {key: value for key, value in plan_arguments.items() if key != "workspace_id"} == approved_plan,
        "presented plan does not exactly match approved-plan.json",
    )
    require(
        isinstance(approved_plan.get("chapters"), list) and len(approved_plan["chapters"]) == 1,
        "fresh proof plan must contain exactly one chapter",
    )

    editor_entries = [entry for entry in entries if entry["toolName"].startswith("native-editor-")]
    require(editor_entries, "proof has no post-approval editor chain")
    chain_roots = {entry["chainRootTurnID"] for entry in editor_entries}
    require(len(chain_roots) == 1, "editor calls do not share one chain root")
    for entry in editor_entries:
        require(is_strict_int(entry.get("chainStep")) and entry["chainStep"] >= 1, f"invalid chain step for {entry['id']}")
    editor_entries.sort(key=lambda entry: entry["chainStep"])
    require([entry["chainStep"] for entry in editor_entries] == list(range(1, len(editor_entries) + 1)), "editor chain steps are not unique and contiguous")
    require(editor_entries[0]["chainRootTurnID"] == editor_entries[0]["sourceTurnID"], "editor chain root is not its approval source turn")
    require(present["chainRootTurnID"] != editor_entries[0]["chainRootTurnID"], "pre-approval plan and editor work share one chain root")
    for previous, current in zip(editor_entries, editor_entries[1:]):
        require(current["sourceTurnID"] == previous["resultTurnID"], "editor chain result/source linkage is broken")

    mutation_entries = [entry for entry in editor_entries if entry["toolName"] in MUTATING_TOOLS]
    require(len(mutation_entries) == 1, "expected exactly one native mutation in the fresh proof flow")
    mutation = mutation_entries[0]
    require(mutation["toolName"] == "native-editor-update-page", "proof mutation must update one lesson")
    mutation_index = editor_entries.index(mutation)
    require(mutation_index > 0, "mutation is not preceded by a verification fetch")
    prior_fetch = editor_entries[mutation_index - 1]
    require(prior_fetch["toolName"] == "native-editor-fetch", "mutation is not immediately preceded by a verification fetch")
    later_fetch = editor_entries[mutation_index + 1] if mutation_index + 1 < len(editor_entries) else None
    if later_fetch is not None:
        require(
            mutation_index + 2 == len(editor_entries),
            "proof contains editor work after the post-mutation verification fetch",
        )
        require(later_fetch["toolName"] == "native-editor-fetch", "mutation is followed by an unexpected editor tool")
    mutation_arguments = parse_embedded_json(mutation["argumentsJSON"], "mutation argumentsJSON")
    page_id = mutation_arguments.get("page_id")
    expected_revision = mutation_arguments.get("expected_revision")
    require(isinstance(page_id, str) and page_id, "mutation is missing page_id")
    require(is_strict_int(expected_revision) and expected_revision >= 1, "mutation has no valid expected_revision")
    mutation_command = mutation_arguments.get("command")
    require(mutation_command in {"replace_content", "update_content"}, "proof mutation command is unsupported")
    if mutation_command == "replace_content":
        require(
            isinstance(mutation_arguments.get("new_str"), str) and mutation_arguments["new_str"].strip(),
            "replace_content mutation has no replacement Markdown",
        )
    else:
        content_updates = mutation_arguments.get("content_updates")
        require(
            isinstance(content_updates, list) and len(content_updates) == 1,
            "update_content proof must contain exactly one content replacement",
        )
        content_update = content_updates[0]
        require(
            isinstance(content_update, dict)
            and set(content_update) == {"old_str", "new_str"}
            and isinstance(content_update["old_str"], str)
            and content_update["old_str"]
            and isinstance(content_update["new_str"], str)
            and content_update["new_str"].strip(),
            "update_content proof has a malformed content replacement",
        )
    require(
        mutation_arguments.get("properties") == {"generation_status": "generated"},
        "proof mutation does not atomically set generation_status to generated",
    )
    require(parse_embedded_json(prior_fetch["argumentsJSON"], "pre-fetch arguments").get("id") == page_id, "pre-mutation fetch inspected another page")
    if later_fetch is not None:
        require(parse_embedded_json(later_fetch["argumentsJSON"], "post-fetch arguments").get("id") == page_id, "post-mutation fetch inspected another page")

    prior_output = parse_embedded_json(prior_fetch["output"], "pre-mutation fetch output")
    mutation_output = parse_embedded_json(mutation["output"], "mutation output")
    require(is_strict_int(prior_output.get("revision")), "pre-mutation result revision must be an integer")
    require(is_strict_int(mutation_output.get("revision")), "mutation result revision must be an integer")
    require(prior_output.get("id") == page_id and prior_output.get("revision") == expected_revision, "mutation did not use the fetched page revision")
    require(mutation_output.get("id") == page_id, "mutation returned another page")
    require(mutation_output.get("revision") == expected_revision + 1, "mutation does not prove one compare-and-swap revision advance")
    if mutation_command == "update_content":
        prior_markdown = prior_output.get("markdown", "")
        require(
            isinstance(prior_markdown, str)
            and prior_markdown.count(content_update["old_str"]) == 1,
            "update_content old_str must occur exactly once in the fetched preimage",
        )
    terminal_editor_entry = mutation
    final_output = mutation_output
    if later_fetch is not None:
        later_output = parse_embedded_json(later_fetch["output"], "post-mutation fetch output")
        require(is_strict_int(later_output.get("revision")), "post-mutation result revision must be an integer")
        require(later_output.get("id") == page_id, "post-mutation fetch returned another page")
        require(later_output.get("revision") == mutation_output.get("revision"), "post-mutation fetch revision mismatch")
        require(later_output.get("markdown") == mutation_output.get("markdown"), "post-mutation fetch content mismatch")
        terminal_editor_entry = later_fetch
        final_output = later_output
    final_markdown = final_output.get("markdown")
    require(isinstance(final_markdown, str) and final_markdown.strip(), "final lesson Markdown is empty")
    verify_swift_example(final_markdown, typecheck=typecheck_swift)

    turns_root = load_json(turns_path, evidence_root)
    require(isinstance(turns_root, dict), "Kittylitter turns evidence must be an object")
    threads = turns_root.get("threads")
    active_runs = turns_root.get("activeRuns")
    submission_intents = turns_root.get("submissionIntents")
    require(isinstance(threads, dict), "Kittylitter turns evidence is missing threads")
    require(isinstance(active_runs, dict), "Kittylitter activeRuns must be an object")
    require(isinstance(submission_intents, dict), "Kittylitter submissionIntents must be an object")
    require(thread_id not in active_runs, "proof thread remains in activeRuns")
    require(thread_id not in submission_intents, "proof thread remains in submissionIntents")
    remote_turns = threads.get(thread_id)
    require(isinstance(remote_turns, list) and remote_turns, "Hermes thread is absent from Kittylitter turns")
    turn_by_id: dict[str, dict[str, Any]] = {}
    calls_by_turn: dict[str, list[dict[str, Any]]] = {}
    results_by_turn: dict[str, list[dict[str, Any]]] = {}
    for turn in remote_turns:
        require(isinstance(turn, dict), "Hermes thread contains a malformed turn")
        turn_id = turn.get("id")
        require(isinstance(turn_id, str) and turn_id, "Hermes turn is missing its ID")
        require(turn_id not in turn_by_id, f"duplicate Hermes turn {turn_id}")
        turn_by_id[turn_id] = turn
        calls = [call for text in item_texts(turn, "agentMessage") if (call := exact_tool_call(text, turn_id)) is not None]
        results = [result for text in item_texts(turn, "userMessage") if (result := exact_tool_result(text, turn_id)) is not None]
        require(len(calls) <= 1, f"turn {turn_id} contains multiple tool calls")
        require(len(results) <= 1, f"turn {turn_id} contains multiple tool results")
        if calls:
            calls_by_turn[turn_id] = calls
        if results:
            results_by_turn[turn_id] = results
    require(set(calls_by_turn) == source_turn_ids, "Hermes thread has missing or unjournaled tool calls")
    require(set(results_by_turn) == result_turn_ids, "Hermes thread has missing or unjournaled tool results")

    approval_source = turn_by_id.get(editor_entries[0]["sourceTurnID"])
    require(approval_source is not None, "first editor source turn is missing")
    expected_approval = normalized_approval_message(approved_plan)
    approval_messages = [
        re.sub(r"\s+", " ", text).strip()
        for text in item_texts(approval_source, "userMessage")
        if "learnfold_tool_result" not in text
    ]
    require(approval_messages == [expected_approval], "first editor call lacks the complete deterministic learner approval")

    for entry in entries:
        source_turn = turn_by_id.get(entry["sourceTurnID"])
        result_turn = turn_by_id.get(entry["resultTurnID"])
        require(source_turn is not None and result_turn is not None, f"missing correlated turns for {entry['id']}")
        require(source_turn.get("status") == "completed", f"source turn {entry['sourceTurnID']} is not completed")
        require(result_turn.get("status") == "completed", f"result turn {entry['resultTurnID']} is not completed")
        remote_call = calls_by_turn[entry["sourceTurnID"]][0]
        require(remote_call["name"] == entry["toolName"], f"source turn tool name mismatch for {entry['id']}")
        require(remote_call["arguments"] == parse_embedded_json(entry["argumentsJSON"], f"journal call {entry['id']} arguments"), f"source turn arguments mismatch for {entry['id']}")
        remote_result = results_by_turn[entry["resultTurnID"]][0]
        expected_result = {
            "call_id": entry["id"],
            "executed_on": "mobile_device",
            "name": entry["toolName"],
            "output": entry["output"],
            "source_turn_id": entry["sourceTurnID"],
            "success": True,
            "workspace_id": workspace_id,
        }
        for key, value in expected_result.items():
            require(remote_result.get(key) == value, f"result field {key} mismatch for {entry['id']}")
        if entry is present:
            require(remote_result.get("approval_status") == "pending", "plan result is not approval-gated")
            require(set(remote_result) == set(expected_result) | {"approval_status"}, "plan result contains unexpected fields")
        else:
            require(set(remote_result) == set(expected_result), f"tool result contains unexpected fields for {entry['id']}")

    final_turn = turn_by_id[terminal_editor_entry["resultTurnID"]]
    require(remote_turns[-1].get("id") == terminal_editor_entry["resultTurnID"], "verified mutation chain is not the terminal Hermes turn")
    final_agent_texts = [text.strip() for text in item_texts(final_turn, "agentMessage") if text.strip()]
    require(len(final_agent_texts) == 1, "final result turn must contain one learner-facing Hermes response")
    require("learnfold_tool_call" not in final_agent_texts[0], "final Hermes response requests another tool")
    try:
        final_json = json.loads(final_agent_texts[0])
    except json.JSONDecodeError:
        final_json = None
    require(not isinstance(final_json, (dict, list)), "final Hermes response is JSON rather than learner-facing prose")

    bindings_root = load_json(threads_path, evidence_root)
    bindings = bindings_root.get("bindings") if isinstance(bindings_root, dict) else None
    require(isinstance(bindings, list), "Kittylitter binding evidence is missing bindings")
    require(all(isinstance(binding, dict) for binding in bindings), "Kittylitter bindings contain malformed rows")
    matching_bindings = [binding for binding in bindings if binding.get("threadId") == thread_id]
    require(len(matching_bindings) == 1, "expected one durable Hermes binding for the proof thread")
    binding = matching_bindings[0]
    require(binding.get("model") == expected_model, "binding does not use the exact expected Hermes model")
    require(binding.get("cwd") == f"/__learnfold_device_owned__/{workspace_id}", "binding cwd is not the device-owned sentinel")
    require(binding.get("approvalPolicy") == "never", "binding approval policy mismatch")
    require(binding.get("approvalsReviewer") == "user", "binding approvals reviewer mismatch")
    require(isinstance(binding.get("hermesSessionId"), str) and binding["hermesSessionId"], "binding has no Hermes session")

    submissions = load_json(submissions_path, evidence_root)
    require(isinstance(submissions, list), "submission journal must be an array")
    require(all(isinstance(record, dict) for record in submissions), "submission journal contains malformed rows")
    require(not submissions, "fresh terminal proof workspace still has a pending phone submission")

    temporary_database, native_database_path, database = sqlite_snapshot(database_path, evidence_root)
    try:
        require(database.execute("PRAGMA user_version").fetchone()[0] == 3, "course database schema version is not 3")
        require(database.execute("PRAGMA quick_check").fetchone()[0] == "ok", "course database quick_check failed")
        require(not database.execute("PRAGMA foreign_key_check").fetchall(), "course database foreign-key check failed")
        database_objects = {
            row[0]
            for row in database.execute(
                "SELECT name FROM sqlite_master WHERE type IN ('table', 'view')"
            )
        }
        require(REQUIRED_DATABASE_OBJECTS <= database_objects, "course database schema objects are incomplete")
        columns = {row[1] for row in database.execute("PRAGMA table_info(page_documents)")}
        require(REQUIRED_PAGE_COLUMNS <= columns, "course database page_documents schema is incomplete")
        database.row_factory = sqlite3.Row
        rows = database.execute(
            "SELECT page_id, document_json, plain_text, revision, checksum, typeof(revision) AS revision_type "
            "FROM page_documents"
        ).fetchall()
        root_metadata_rows = database.execute(
            "SELECT value FROM metadata WHERE key = 'root_page_id'"
        ).fetchall()
        library_rows = database.execute(
            "SELECT id, kind, parent_id, title, trashed_at FROM library_items"
        ).fetchall()
        target_history_rows = database.execute(
            "SELECT page_id, document_json FROM page_history WHERE page_id = ? ORDER BY created_at DESC",
            (page_id,),
        ).fetchall()
        inspection = native_inspection(native_helper, native_database_path, page_id)
    except sqlite3.Error as error:
        raise EvidenceError(f"could not inspect course database snapshot: {error}") from error
    finally:
        database.close()
        temporary_database.cleanup()
    require(rows, "course database contains no pages")
    page_records: dict[str, tuple[sqlite3.Row, dict[str, Any], dict[str, Any]]] = {}
    for row in rows:
        require(row["revision_type"] == "integer", f"page {row['page_id']} revision is not stored as an integer")
        raw_document = row["document_json"]
        require(isinstance(raw_document, bytes), f"page {row['page_id']} document_json must be a BLOB")
        require(hashlib.sha256(raw_document).hexdigest() == row["checksum"], f"page {row['page_id']} checksum mismatch")
        try:
            document = json.loads(raw_document)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise EvidenceError(f"page {row['page_id']} document_json is invalid: {error}") from error
        require(isinstance(document, dict), f"page {row['page_id']} document must be an object")
        root = document.get("document")
        require(isinstance(root, dict) and isinstance(root.get("data"), dict), f"page {row['page_id']} metadata is invalid")
        page_records[row["page_id"]] = (row, document, root["data"])
    require(page_id in page_records, "mutated lesson is absent from the course database")
    lesson_row, lesson_document, lesson_metadata = page_records[page_id]
    require(inspection.get("pageID") == page_id, "native helper inspected another page")
    require(is_strict_int(inspection.get("revision")), "native helper revision must be an integer")
    require(inspection.get("markdown") == final_markdown, "native document content differs from the verified tool result")
    require(lesson_row["plain_text"] == inspection.get("plainText"), "native page plain_text index does not match document_json")
    require(lesson_row["checksum"] == inspection.get("documentSHA256"), "native helper document checksum mismatch")
    require(lesson_row["revision"] == mutation_output["revision"], "native database revision differs from the verified fetch")
    require(inspection["revision"] == lesson_row["revision"], "native helper revision differs from the database")
    require(lesson_metadata.get("course_role") == "lesson" and lesson_metadata.get("course_generation_status") == "generated", "target page is not a generated lesson")
    metadata = [record[2] for record in page_records.values()]
    course_rows = [data for data in metadata if data.get("course_role") == "course"]
    require(len(course_rows) == 1 and course_rows[0].get("course_bootstrap_status") == "ready_for_learning", "native course is not ready for learning")
    require(sum(data.get("course_role") == "chapter" for data in metadata) == 1, "native database must contain exactly one chapter")
    require(sum(data.get("course_role") == "lesson" for data in metadata) == 1, "native database must contain exactly one lesson")

    require(len(root_metadata_rows) == 1, "native database has no unique root_page_id metadata")
    root_page_id = root_metadata_rows[0][0]
    require(root_page_id in page_records, "native root_page_id does not identify a page")
    require(page_records[root_page_id][2].get("course_role") == "course", "native root page is not the course")
    require(all(row[4] is None for row in library_rows), "fresh proof contains trashed library items")
    item_by_id = {row[0]: row for row in library_rows}
    require(len(item_by_id) == len(library_rows), "native library contains duplicate item IDs")
    library_root_id = "__native_editor_library_root__"
    require(
        set(item_by_id) == set(page_records) | {library_root_id},
        "native library/page-document inventory mismatch",
    )
    require(
        item_by_id[library_root_id][1:4] == ("folder", None, "Library"),
        "native library root sentinel is malformed",
    )
    require(all(row[1] == "page" for row in library_rows if row[0] != library_root_id), "fresh proof library contains unexpected non-page items")
    require(item_by_id[root_page_id][2] == library_root_id, "course root is outside the native library root")

    context_items = [
        item_by_id[record_id]
        for record_id, (_, _, data) in page_records.items()
        if data.get("course_role") == "context"
    ]
    require(len(context_items) == 3, "native course does not contain exactly three context pages")
    require(
        sorted(item[3] for item in context_items) == ["Agent notes", "Course design", "Learner profile"],
        "native course context-page titles are incomplete",
    )
    require(all(item[2] == root_page_id for item in context_items), "native course context pages are outside the root")
    require(
        sum(data.get("course_role") == "context" for data in metadata) == 3,
        "native course context roles are incomplete",
    )
    chapter_ids = [record_id for record_id, (_, _, data) in page_records.items() if data.get("course_role") == "chapter"]
    require(item_by_id[chapter_ids[0]][2] == root_page_id, "native chapter is outside the course root")
    require(item_by_id[page_id][2] == chapter_ids[0], "mutated lesson is outside the verified chapter")

    require(
        len(target_history_rows) == 1 and target_history_rows[0][0] == page_id,
        "fresh proof lacks one lesson preimage history row",
    )
    require(
        inspection.get("historyMarkdown") == [prior_output.get("markdown")],
        "native lesson history does not preserve the fetched pre-mutation content",
    )

    return {
        "status": "artifact_consistency_verified",
        "proof_boundary": "artifact consistency only; physical-device and background provenance require trusted review of raw device, signing, media, and app-log evidence",
        "workspace_id": workspace_id,
        "thread_id": thread_id,
        "device_udid": manifest["device"]["udid"],
        "device_os": manifest["device"]["os_version"],
        "app_bundle_id": manifest["app"]["bundle_id"],
        "hermes_session_id": binding["hermesSessionId"],
        "model": binding["model"],
        "tool_calls": len(entries),
        "tool_results_returned": len(entries),
        "mutation_call_id": mutation["id"],
        "lesson_page_id": page_id,
        "lesson_revision_before": expected_revision,
        "lesson_revision_after": mutation_output["revision"],
        "result_submission_attempts": sum(entry["resultSubmissionAttempts"] for entry in entries),
        "pending_remote_runs": 0,
        "pending_phone_submissions": 0,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workspace", type=Path, help="fresh exported iPhone course workspace")
    parser.add_argument("--bridge-state", type=Path, required=True, help="captured Kittylitter bridge-state directory")
    parser.add_argument("--run-manifest", type=Path, required=True, help="captured run manifest with device, lifecycle, and hashes")
    parser.add_argument("--expected-model", required=True, help="exact Hermes model ID expected in the durable binding")
    parser.add_argument("--expected-bundle-id", required=True, help="exact signed Learnfold application bundle ID")
    parser.add_argument("--native-helper", type=Path, required=True, help="built native-editor-evidence-helper executable")
    parser.add_argument("--ffprobe", type=Path, help="ffprobe executable; defaults to PATH lookup")
    parser.add_argument("--skip-swift-typecheck", action="store_true", help="skip xcrun swiftc; intended only for verifier unit tests")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        summary = verify_workspace(
            args.workspace,
            args.bridge_state,
            args.run_manifest,
            args.expected_model,
            args.expected_bundle_id,
            args.native_helper,
            typecheck_swift=not args.skip_swift_typecheck,
            ffprobe=args.ffprobe,
        )
    except (EvidenceError, OSError, subprocess.SubprocessError) as error:
        print(json.dumps({"status": "failed", "error": str(error)}, indent=2), file=sys.stderr)
        return 1
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
