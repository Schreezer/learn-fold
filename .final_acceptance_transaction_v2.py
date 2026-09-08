#!/usr/bin/env python3
"""One-shot D0FB predecessor retirement and frozen-app install transaction.

This operational harness is intentionally root-specific. It performs no app
launch and never retries install or uninstall. Unknown command outcomes are
reconciled from durable simulator/container state before proceeding.
"""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import hashlib
import json
import os
import pwd
import re
import signal
import socket
import stat
import struct
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any


MATRIX_ROOT = Path("/Users/Shared/LearnfoldProductionReadiness-20260824T112708Z")
EVIDENCE = MATRIX_ROOT / "evidence"
AUTHORITY = MATRIX_ROOT / "sealed-authority"
APP = EVIDENCE / "DebugDerivedData/Build/Products/Debug-iphonesimulator/Litter.app"
UDID = "D0FB9369-BFB4-4966-B677-2F42CDE0B218"
HISTORICAL_UDID = "2ABF8F31-6E24-4308-9ED9-32CF3CAE54D3"
BUNDLE_ID = "com.chirag.learnfold"
EXPECTED_NAME = "Learnfold Postfix QA 20260817"
EXPECTED_RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
EXPECTED_DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
SCRIPT_PATH = Path(__file__).resolve()
SECRET_PATTERN = re.compile(rb"(?i)(authorization:|bearer\s|api[_-]?key|password=|token=)")
EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()


class TransactionError(RuntimeError):
    pass


class SignalAbort(TransactionError):
    pass


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_flags(path: Path) -> int:
    return int(subprocess.check_output(["/usr/bin/stat", "-f", "%f", str(path)], text=True).strip())


def identity(path: Path, *, hash_regular: bool = False) -> dict[str, Any]:
    item = os.lstat(path)
    mode = item.st_mode
    if stat.S_ISDIR(mode):
        kind = "directory"
    elif stat.S_ISREG(mode):
        kind = "regular"
    elif stat.S_ISLNK(mode):
        kind = "symlink"
    elif stat.S_ISSOCK(mode):
        kind = "socket"
    else:
        kind = "other"
    result: dict[str, Any] = {
        "path": str(path),
        "realpath": os.path.realpath(path),
        "type": kind,
        "dev": item.st_dev,
        "inode": item.st_ino,
        "uid": item.st_uid,
        "mode": f"0o{stat.S_IMODE(mode):04o}",
        "flags": file_flags(path),
        "bytes": item.st_size,
    }
    if hash_regular and kind == "regular":
        result["sha256"] = sha256_file(path)
    return result


def fsync_dir(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def write_exclusive(path: Path, raw: bytes, mode: int = 0o600) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, mode)
    try:
        view = memoryview(raw)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise TransactionError(f"short write: {path}")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    fsync_dir(path.parent)


def seal(path: Path) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise TransactionError(f"seal target is not a regular file: {path}")
    os.chmod(path, 0o444, follow_symlinks=False)
    subprocess.run(["/usr/bin/chflags", "uchg", str(path)], check=True, capture_output=True)
    result = identity(path, hash_regular=True)
    if result["mode"] != "0o0444" or result["flags"] & 2 != 2:
        raise TransactionError(f"sealed identity mismatch: {path}")
    return result


class Publisher:
    def __init__(self, root: Path):
        self.root = root

    def json(self, name: str, value: Any) -> dict[str, Any]:
        path = self.root / name
        raw = canonical_bytes(value)
        write_exclusive(path, raw)
        if json.loads(path.read_bytes()) != value:
            raise TransactionError(f"receipt readback mismatch: {name}")
        item = seal(path)
        sidecar = path.with_name(path.name + ".sha256")
        write_exclusive(sidecar, f"{item['sha256']}  {path.name}\n".encode("ascii"))
        sidecar_item = seal(sidecar)
        if sidecar.read_text(encoding="ascii").split()[0] != item["sha256"]:
            raise TransactionError(f"sidecar readback mismatch: {name}")
        return {"artifact": item, "sidecar": sidecar_item}

    def seal_existing(self, path: Path) -> dict[str, Any]:
        if path.parent != self.root:
            raise TransactionError(f"artifact outside transaction root: {path}")
        item = seal(path)
        sidecar = path.with_name(path.name + ".sha256")
        write_exclusive(sidecar, f"{item['sha256']}  {path.name}\n".encode("ascii"))
        sidecar_item = seal(sidecar)
        return {"artifact": item, "sidecar": sidecar_item}


def bundle_hash(root: Path) -> str:
    real_root = Path(os.path.realpath(root))
    digest = hashlib.sha256()

    def add(tag: bytes, relative: str, payload: bytes) -> None:
        relative_bytes = os.fsencode(relative)
        digest.update(tag)
        digest.update(struct.pack(">Q", len(relative_bytes)))
        digest.update(relative_bytes)
        digest.update(struct.pack(">Q", len(payload)))
        digest.update(payload)

    def walk(directory: Path, prefix: str = "") -> None:
        entries = sorted(os.scandir(directory), key=lambda item: os.fsencode(item.name))
        for entry in entries:
            relative = entry.name if not prefix else f"{prefix}/{entry.name}"
            before = entry.stat(follow_symlinks=False)
            if stat.S_ISLNK(before.st_mode):
                add(b"L", relative, os.fsencode(os.readlink(entry.path)))
            elif stat.S_ISDIR(before.st_mode):
                add(b"D", relative, b"")
                walk(Path(entry.path), relative)
            elif stat.S_ISREG(before.st_mode):
                file_digest = hashlib.sha256()
                byte_count = 0
                descriptor = os.open(entry.path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
                try:
                    opened = os.fstat(descriptor)
                    if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
                        raise TransactionError(f"bundle entry identity changed: {relative}")
                    while True:
                        chunk = os.read(descriptor, 1024 * 1024)
                        if not chunk:
                            break
                        byte_count += len(chunk)
                        file_digest.update(chunk)
                    after = os.fstat(descriptor)
                finally:
                    os.close(descriptor)
                compared = ("st_dev", "st_ino", "st_mode", "st_size", "st_mtime_ns")
                if any(getattr(before, key) != getattr(after, key) for key in compared) or byte_count != before.st_size:
                    raise TransactionError(f"bundle entry changed while hashing: {relative}")
                add(b"F", relative, file_digest.digest())
            else:
                raise TransactionError(f"unsupported bundle node: {relative}")

    walk(real_root)
    return digest.hexdigest()


def run_capture(argv: list[str], *, timeout: float, env: dict[str, str] | None = None) -> dict[str, Any]:
    started = utc_now()
    monotonic = time.monotonic()
    try:
        completed = subprocess.run(argv, capture_output=True, timeout=timeout, env=env)
        stdout = completed.stdout
        stderr = completed.stderr
        return {
            "argv": argv,
            "started_at_utc": started,
            "ended_at_utc": utc_now(),
            "elapsed_seconds": round(time.monotonic() - monotonic, 6),
            "outcome": "returned",
            "exit": completed.returncode,
            "stdout_bytes": len(stdout),
            "stdout_sha256": hashlib.sha256(stdout).hexdigest(),
            "stderr_bytes": len(stderr),
            "stderr_sha256": hashlib.sha256(stderr).hexdigest(),
            "_stdout": stdout,
            "_stderr": stderr,
        }
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout or b""
        stderr = error.stderr or b""
        return {
            "argv": argv,
            "started_at_utc": started,
            "ended_at_utc": utc_now(),
            "elapsed_seconds": round(time.monotonic() - monotonic, 6),
            "outcome": "timeout",
            "exit": None,
            "timeout_seconds": timeout,
            "stdout_bytes": len(stdout),
            "stdout_sha256": hashlib.sha256(stdout).hexdigest(),
            "stderr_bytes": len(stderr),
            "stderr_sha256": hashlib.sha256(stderr).hexdigest(),
            "_stdout": stdout,
            "_stderr": stderr,
        }


def public_result(result: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in result.items() if not key.startswith("_")}


def simulator_inventory() -> dict[str, Any]:
    result = run_capture(["xcrun", "simctl", "list", "devices", "--json"], timeout=30)
    if result["outcome"] != "returned" or result["exit"] != 0:
        raise TransactionError("simulator inventory command failed")
    try:
        parsed = json.loads(result["_stdout"].decode("utf-8"))
    except Exception as error:
        raise TransactionError(f"simulator inventory malformed: {error}") from error
    if not isinstance(parsed, dict) or not isinstance(parsed.get("devices"), dict):
        raise TransactionError("simulator inventory schema invalid")
    return parsed


def simulator_entry(inventory: dict[str, Any], udid: str) -> tuple[str, dict[str, Any]]:
    matches: list[tuple[str, dict[str, Any]]] = []
    for runtime, rows in inventory["devices"].items():
        if not isinstance(rows, list):
            raise TransactionError("simulator inventory device rows invalid")
        for row in rows:
            if isinstance(row, dict) and row.get("udid") == udid:
                matches.append((runtime, row))
    if len(matches) != 1:
        raise TransactionError(f"simulator identity cardinality invalid: {udid}:{len(matches)}")
    return matches[0]


def container(kind: str) -> dict[str, Any]:
    result = run_capture(["xcrun", "simctl", "get_app_container", UDID, BUNDLE_ID, kind], timeout=30)
    stdout = result.pop("_stdout")
    result.pop("_stderr")
    path = stdout.decode("utf-8", errors="strict").strip() if result["outcome"] == "returned" else ""
    result["kind"] = kind
    result["path"] = path if path.startswith("/") else None
    result["present"] = result["exit"] == 0 and result["path"] is not None and Path(result["path"]).exists()
    return result


def app_processes() -> list[dict[str, Any]]:
    result = run_capture(["xcrun", "simctl", "spawn", UDID, "/bin/ps", "-axo", "pid=,uid=,command="], timeout=30)
    if result["outcome"] != "returned" or result["exit"] != 0:
        raise TransactionError("app process inventory failed")
    text = result["_stdout"].decode("utf-8", errors="strict")
    rows = []
    for line in text.splitlines():
        if "/Litter.app/Litter" not in line and BUNDLE_ID not in line:
            continue
        match = re.match(r"\s*(\d+)\s+(\d+)\s+(.*)$", line)
        if not match:
            raise TransactionError("app process inventory row malformed")
        rows.append({"pid": int(match.group(1)), "uid": int(match.group(2)), "command_sha256": hashlib.sha256(match.group(3).encode()).hexdigest()})
    return rows


def canonical_absences() -> list[dict[str, Any]]:
    required = [
        ("paired-captures.jsonl", "file"),
        ("paired-capture-reviews.jsonl", "file"),
        ("restart-receipts", "directory"),
        ("final-acceptance-seal.json", "file"),
        (".capture-pair.lock", "directory"),
    ]
    result = []
    for relative, expected_kind in required:
        path = AUTHORITY / relative
        result.append({"path": str(path), "relative_path": relative, "expected_kind": expected_kind, "absent": not os.path.lexists(path)})
    return result


def validate_script_identity() -> dict[str, Any]:
    item = identity(SCRIPT_PATH, hash_regular=True)
    if item["type"] != "regular" or item["uid"] != os.getuid() or item["mode"] != "0o0444" or item["flags"] & 2 != 2:
        raise TransactionError("transaction script is not sealed")
    return item


def validate_matrix() -> dict[str, Any]:
    terminal_path = EVIDENCE / "matrix-execution-result.json"
    terminal = json.loads(terminal_path.read_text(encoding="utf-8"))
    if terminal.get("exit_status") != 0 or terminal.get("signal") != "none" or terminal.get("phase") != "child":
        raise TransactionError("matrix terminal result is not successful")
    frozen_path = AUTHORITY / "frozen-manifest.json"
    frozen = json.loads(frozen_path.read_text(encoding="utf-8"))
    if frozen.get("simulator_udid") != UDID or frozen.get("bundle_id") != BUNDLE_ID:
        raise TransactionError("frozen manifest target mismatch")
    source_inventory = AUTHORITY / "frozen-source-inventory.json"
    build_inventory = AUTHORITY / "frozen-build-inventory.json"
    if sha256_file(source_inventory) != frozen["source"]["identity_sha256"]:
        raise TransactionError("frozen source identity mismatch")
    if sha256_file(build_inventory) != frozen["build"]["identity_sha256"]:
        raise TransactionError("frozen build identity mismatch")
    actual_bundle = bundle_hash(APP)
    actual_executable = sha256_file(APP / frozen["artifact"]["executable_name"])
    if actual_bundle != frozen["artifact"]["bundle_sha256"] or actual_executable != frozen["artifact"]["executable_sha256"]:
        raise TransactionError("candidate app identity mismatch")
    idb_identity_path = EVIDENCE / "dev-projection-idb-identity.json"
    idb = json.loads(idb_identity_path.read_text(encoding="utf-8"))
    if idb.get("identity_sha256") != frozen["idb"]["identity_sha256"]:
        raise TransactionError("frozen idb identity mismatch")
    interpreter = Path(idb["interpreter"]["reported_executable"])
    idb_script = Path(idb["resolved_executable_path"])
    if os.path.realpath(interpreter) != idb["interpreter"]["reported_executable_realpath"]:
        raise TransactionError("idb interpreter realpath mismatch")
    if sha256_file(Path(os.path.realpath(interpreter))) != idb["interpreter"]["executable_sha256"]:
        raise TransactionError("idb interpreter hash mismatch")
    if sha256_file(idb_script) != idb["executable_sha256"]:
        raise TransactionError("idb script hash mismatch")
    companion_launch_path = EVIDENCE / "dev-projection-companion-launch.json"
    companion_launch = json.loads(companion_launch_path.read_text(encoding="utf-8"))
    companion = Path(companion_launch["binary"])
    if os.path.realpath(companion) != str(companion) or sha256_file(companion) != companion_launch["binary_sha256"]:
        raise TransactionError("companion binary identity mismatch")
    sidecar_failures = []
    for sidecar in list(EVIDENCE.glob("*.sha256")) + list(AUTHORITY.glob("*.sha256")):
        fields = sidecar.read_text(encoding="utf-8").split()
        if len(fields) < 2:
            sidecar_failures.append(str(sidecar))
            continue
        target = sidecar.parent / fields[-1].lstrip("*")
        if not target.exists() or sha256_file(target) != fields[0]:
            sidecar_failures.append(str(sidecar))
    if sidecar_failures:
        raise TransactionError(f"matrix sidecar mismatch count={len(sidecar_failures)}")
    return {
        "terminal": identity(terminal_path, hash_regular=True),
        "frozen_manifest": identity(frozen_path, hash_regular=True),
        "frozen_source_inventory": identity(source_inventory, hash_regular=True),
        "frozen_build_inventory": identity(build_inventory, hash_regular=True),
        "acceptance_tool_handoff": identity(EVIDENCE / "acceptance-tool-handoff.txt", hash_regular=True),
        "sealed_authority_receipt": identity(EVIDENCE / "sealed-authority-receipt.txt", hash_regular=True),
        "idb_identity": identity(idb_identity_path, hash_regular=True),
        "companion_launch_authority": identity(companion_launch_path, hash_regular=True),
        "candidate_app": {
            "path": str(APP),
            "bundle_sha256": actual_bundle,
            "executable_name": frozen["artifact"]["executable_name"],
            "executable_sha256": actual_executable,
        },
        "idb_interpreter": str(interpreter),
        "idb_script": str(idb_script),
        "idb_distribution": idb["package"]["distribution_location"],
        "companion_binary": str(companion),
        "companion_binary_sha256": companion_launch["binary_sha256"],
        "sidecar_count": len(list(EVIDENCE.glob("*.sha256")) + list(AUTHORITY.glob("*.sha256"))),
    }


def validate_simulator() -> dict[str, Any]:
    inventory = simulator_inventory()
    runtime, row = simulator_entry(inventory, UDID)
    if runtime != EXPECTED_RUNTIME or row.get("name") != EXPECTED_NAME or row.get("deviceTypeIdentifier") != EXPECTED_DEVICE_TYPE:
        raise TransactionError("acceptance simulator identity mismatch")
    if row.get("state") != "Booted" or row.get("isAvailable") is not True:
        raise TransactionError("acceptance simulator is not available and Booted")
    historical_runtime, historical = simulator_entry(inventory, HISTORICAL_UDID)
    if historical.get("isAvailable") is not True:
        raise TransactionError("historical protected simulator is unavailable")
    return {
        "acceptance": {"runtime": runtime, **row},
        "historical": {"runtime": historical_runtime, **historical},
        "inventory_sha256": hashlib.sha256(canonical_bytes(inventory)).hexdigest(),
    }


def existing_leases() -> list[dict[str, Any]]:
    result = []
    for value in sorted(glob.glob("/Users/Shared/LearnfoldD0FB*/d0fb-exclusive.lease")):
        path = Path(value)
        if os.path.lexists(path):
            result.append(identity(path, hash_regular=False))
    return result


def preflight() -> dict[str, Any]:
    script = validate_script_identity()
    matrix = validate_matrix()
    simulator = validate_simulator()
    app = container("app")
    data = container("data")
    processes = app_processes()
    if not app["present"] or not data["present"]:
        raise TransactionError("expected predecessor app/data container is absent")
    predecessor_app = Path(app["path"])
    predecessor_bundle = bundle_hash(predecessor_app)
    predecessor_executable = sha256_file(predecessor_app / "Litter")
    if predecessor_bundle == matrix["candidate_app"]["bundle_sha256"]:
        raise TransactionError("current frozen app is already installed; refusing a second install")
    if processes:
        raise TransactionError("predecessor app process is still running")
    leases = existing_leases()
    if leases:
        raise TransactionError(f"existing D0FB lease count={len(leases)}")
    absences = canonical_absences()
    if not all(item["absent"] for item in absences):
        raise TransactionError("current authority already contains acceptance outputs")
    return {
        "schema": "learnfold-d0fb-final-preflight-v2",
        "checked_at_utc": utc_now(),
        "script": script,
        "matrix": matrix,
        "simulator": simulator,
        "predecessor": {
            "app_container": identity(predecessor_app),
            "data_container": identity(Path(data["path"])),
            "bundle_sha256": predecessor_bundle,
            "executable_sha256": predecessor_executable,
            "processes": processes,
        },
        "canonical_absences": absences,
        "existing_leases": leases,
    }


def parse_application(raw: bytes) -> dict[str, Any]:
    if SECRET_PATTERN.search(raw):
        raise TransactionError("preinstall AX output contains secret-like material")
    try:
        value = json.loads(raw.decode("utf-8"))
    except Exception as error:
        raise TransactionError(f"preinstall AX output is malformed: {error}") from error
    if not isinstance(value, list) or len(value) != 1 or not isinstance(value[0], dict):
        raise TransactionError("preinstall AX root cardinality invalid")
    root = value[0]
    frame = root.get("frame")
    if root.get("type") != "Application" or not isinstance(frame, dict) or not isinstance(root.get("children"), list):
        raise TransactionError("preinstall AX root schema invalid")
    numbers = []
    for key in ("x", "y", "width", "height"):
        item = frame.get(key)
        if not isinstance(item, (int, float)) or isinstance(item, bool) or not float(item) == float(item):
            raise TransactionError("preinstall AX frame invalid")
        numbers.append(float(item))
    if numbers[2] <= 0 or numbers[3] <= 0:
        raise TransactionError("preinstall AX frame is nonpositive")
    return {
        "root_type": "Application",
        "frame": {key: frame[key] for key in ("x", "y", "width", "height")},
        "children_count": len(root["children"]),
    }


def owned_pgid_rows(pgid: int) -> list[dict[str, Any]]:
    completed = subprocess.run(["/bin/ps", "-axo", "pid=,pgid=,uid=,command="], capture_output=True, text=True, check=True)
    rows = []
    for line in completed.stdout.splitlines():
        match = re.match(r"\s*(\d+)\s+(\d+)\s+(\d+)\s+(.*)$", line)
        if not match or int(match.group(2)) != pgid:
            continue
        uid = int(match.group(3))
        if uid != os.getuid():
            raise TransactionError(f"foreign process found in companion group: {match.group(1)}")
        rows.append({"pid": int(match.group(1)), "pgid": pgid, "uid": uid, "command_sha256": hashlib.sha256(match.group(4).encode()).hexdigest()})
    return rows


def stop_companion(process: subprocess.Popen[bytes], pgid: int) -> dict[str, Any]:
    before = owned_pgid_rows(pgid)
    if process.poll() is None:
        os.killpg(pgid, signal.SIGTERM)
    deadline = time.monotonic() + 15
    process.poll()
    while time.monotonic() < deadline and owned_pgid_rows(pgid):
        time.sleep(0.05)
        process.poll()
    after_term = owned_pgid_rows(pgid)
    if after_term:
        os.killpg(pgid, signal.SIGKILL)
        deadline = time.monotonic() + 10
        process.poll()
        while time.monotonic() < deadline and owned_pgid_rows(pgid):
            time.sleep(0.05)
            process.poll()
    try:
        returncode = process.wait(timeout=5)
    except subprocess.TimeoutExpired as error:
        raise TransactionError("companion leader was not reaped") from error
    after = owned_pgid_rows(pgid)
    if after:
        raise TransactionError("companion process group remains live")
    return {"before": before, "after_term": after_term, "after": after, "leader_returncode": returncode, "reaped": True}


def unlink_owned_socket(path: Path, root: Path) -> dict[str, Any]:
    if path.parent != root or os.path.realpath(root) != str(root):
        raise TransactionError("companion socket containment invalid")
    item = identity(path)
    if item["type"] != "socket" or item["uid"] != os.getuid():
        raise TransactionError("companion socket identity invalid")
    os.unlink(path)
    fsync_dir(root)
    if os.path.lexists(path):
        raise TransactionError("companion socket remains after unlink")
    return {"before": item, "absent_after": True}


def probe_unix_socket_path(path: Path, root: Path) -> dict[str, Any]:
    encoded_bytes = len(os.fsencode(str(path)))
    if path.parent != root or encoded_bytes > 100:
        raise TransactionError(f"companion socket path is not Darwin-safe: bytes={encoded_bytes}")
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        probe.bind(str(path))
        bound = identity(path)
        if bound["type"] != "socket" or bound["uid"] != os.getuid():
            raise TransactionError("companion socket probe identity invalid")
    finally:
        probe.close()
        if os.path.lexists(path):
            os.unlink(path)
            fsync_dir(root)
    if os.path.lexists(path):
        raise TransactionError("companion socket probe remains after unlink")
    return {
        "path": str(path),
        "encoded_bytes": encoded_bytes,
        "bind_succeeded": True,
        "socket_absent_after": True,
    }


def remove_owned_socket_root(root: Path, expected: dict[str, Any]) -> dict[str, Any]:
    current = identity(root)
    stable = ("path", "realpath", "type", "dev", "inode", "uid", "mode")
    if any(current[key] != expected[key] for key in stable):
        raise TransactionError("companion socket root identity changed")
    if current["type"] != "directory" or current["uid"] != os.getuid() or current["mode"] != "0o0700":
        raise TransactionError("companion socket root is unsafe")
    if list(os.scandir(root)):
        raise TransactionError("companion socket root is not empty")
    os.rmdir(root)
    fsync_dir(root.parent)
    if os.path.lexists(root):
        raise TransactionError("companion socket root remains after removal")
    return {"before": current, "absent_after": True}


def close_failed_preinstall_attempt(root: Path) -> dict[str, Any]:
    root = Path(os.path.realpath(root))
    if root.parent != Path("/Users/Shared") or not root.name.startswith("LearnfoldD0FBFinalAcceptance-final2-"):
        raise TransactionError("failed attempt root is outside the exact allowed namespace")
    terminal_path = root / "terminal-failure.json"
    cleanup_path = root / "companion-cleanup.json"
    lease_receipt_path = root / "lease-acquisition.json"
    required = (terminal_path, cleanup_path, lease_receipt_path, root / "preflight.json")
    if any(path.is_symlink() or not path.is_file() for path in required):
        raise TransactionError("failed attempt receipts are missing or unsafe")
    terminal = json.loads(terminal_path.read_text(encoding="utf-8"))
    cleanup = json.loads(cleanup_path.read_text(encoding="utf-8"))
    lease_receipt = json.loads(lease_receipt_path.read_text(encoding="utf-8"))
    if terminal.get("schema") != "learnfold-d0fb-final-transaction-failure-v2":
        raise TransactionError("failed attempt terminal schema mismatch")
    if terminal.get("install_attempted") is not False or terminal.get("uninstall_attempted") is not False:
        raise TransactionError("failed attempt crossed the destructive boundary")
    if cleanup.get("install_attempted") is not False or cleanup.get("uninstall_attempted") is not False:
        raise TransactionError("failed attempt cleanup disagrees about mutation")
    group = cleanup.get("process_group") or {}
    socket_cleanup = cleanup.get("socket") or {}
    if group.get("reaped") is not True or group.get("after") != [] or socket_cleanup.get("absent_after") is not True:
        raise TransactionError("failed attempt companion cleanup is incomplete")
    forbidden = (
        "predecessor-retirement-intent.json",
        "predecessor-retirement-result.json",
        "install-intent.json",
        "install-result.json",
        "postinstall-state.json",
        "acceptance-operator-handoff.json",
    )
    if any(os.path.lexists(root / name) for name in forbidden):
        raise TransactionError("failed attempt unexpectedly contains post-gate evidence")

    lease = root / "d0fb-exclusive.lease"
    lease_before = identity(lease, hash_regular=True)
    recorded = lease_receipt.get("lease") or {}
    stable = ("path", "realpath", "type", "dev", "inode", "uid", "mode", "bytes")
    if any(lease_before.get(key) != recorded.get(key) for key in stable):
        raise TransactionError("failed attempt lease identity mismatch")
    if lease_before["type"] != "regular" or lease_before["uid"] != os.getuid() or lease_before["mode"] != "0o0600":
        raise TransactionError("failed attempt lease is unsafe")
    if lease_before["sha256"] != recorded.get("token_sha256"):
        raise TransactionError("failed attempt lease token hash mismatch")

    preflight_receipt = json.loads((root / "preflight.json").read_text(encoding="utf-8"))
    app = container("app")
    data = container("data")
    if not app["present"] or not data["present"] or app_processes():
        raise TransactionError("D0FB state is not the untouched pre-install state")
    app_path = Path(app["path"])
    predecessor = preflight_receipt.get("predecessor") or {}
    observed_bundle = bundle_hash(app_path)
    observed_executable = sha256_file(app_path / "Litter")
    if app["path"] != predecessor.get("app_container", {}).get("path") or data["path"] != predecessor.get("data_container", {}).get("path"):
        raise TransactionError("D0FB predecessor containers changed")
    if observed_bundle != predecessor.get("bundle_sha256") or observed_executable != predecessor.get("executable_sha256"):
        raise TransactionError("D0FB predecessor bytes changed")
    if not all(item["absent"] for item in canonical_absences()):
        raise TransactionError("canonical acceptance output appeared after failed attempt")

    publisher = Publisher(root)
    intent = publisher.json("failed-preinstall-closure-intent.json", {
        "schema": "learnfold-d0fb-failed-preinstall-closure-intent-v1",
        "created_at_utc": utc_now(),
        "closure_script": validate_script_identity(),
        "failed_terminal": identity(terminal_path, hash_regular=True),
        "companion_cleanup": identity(cleanup_path, hash_regular=True),
        "lease_before": lease_before,
        "mutation_boundary": {"uninstall_attempted": False, "install_attempted": False, "launch_attempted": False},
        "untouched_predecessor": {"app": app, "data": data, "bundle_sha256": observed_bundle, "executable_sha256": observed_executable},
        "canonical_absences": canonical_absences(),
        "action": "unlink-exact-failed-attempt-lease",
    })
    before_unlink = os.lstat(lease)
    if (before_unlink.st_dev, before_unlink.st_ino, before_unlink.st_uid) != (lease_before["dev"], lease_before["inode"], lease_before["uid"]):
        raise TransactionError("failed attempt lease changed before unlink")
    os.unlink(lease)
    fsync_dir(root)
    if os.path.lexists(lease):
        raise TransactionError("failed attempt lease remains after unlink")
    result = publisher.json("failed-preinstall-closure-result.json", {
        "schema": "learnfold-d0fb-failed-preinstall-closure-result-v1",
        "created_at_utc": utc_now(),
        "intent_sha256": intent["artifact"]["sha256"],
        "lease_before": lease_before,
        "lease_absent_after": True,
        "untouched_predecessor": {
            "app": container("app"),
            "data": container("data"),
            "bundle_sha256": bundle_hash(app_path),
            "executable_sha256": sha256_file(app_path / "Litter"),
            "processes": app_processes(),
        },
        "canonical_absences": canonical_absences(),
        "new_transaction_authorized": True,
    })
    return {"status": "passed", "root": str(root), "result": result}


def execute_transaction(pre: dict[str, Any]) -> dict[str, Any]:
    transaction_id = f"final2-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}-{uuid.uuid4().hex[:12]}"
    out = Path("/Users/Shared") / f"LearnfoldD0FBFinalAcceptance-{transaction_id}"
    if os.path.lexists(out):
        raise TransactionError("transaction root already exists")
    os.mkdir(out, 0o700)
    fsync_dir(out.parent)
    publisher = Publisher(out)
    pre_receipt = publisher.json("preflight.json", {**pre, "transaction_id": transaction_id, "transaction_root": str(out)})

    token = uuid.uuid4().hex + uuid.uuid4().hex
    lease = out / "d0fb-exclusive.lease"
    write_exclusive(lease, token.encode("ascii"), 0o600)
    lease_item = identity(lease)
    lease_item["token_sha256"] = hashlib.sha256(token.encode("ascii")).hexdigest()
    lease_receipt = publisher.json("lease-acquisition.json", {"schema": "learnfold-d0fb-lease-v2", "transaction_id": transaction_id, "lease": lease_item})

    tmp = out / "tmp"
    socket_root = Path("/Users/Shared") / f"LF4-{transaction_id.rsplit('-', 1)[-1]}"
    os.mkdir(tmp, 0o700)
    os.mkdir(socket_root, 0o700)
    fsync_dir(out)
    socket_path = socket_root / "fb-idb.sock"
    socket_root_item = identity(socket_root)
    socket_probe = probe_unix_socket_path(socket_path, socket_root)
    companion_stdout = out / "companion.stdout.log"
    companion_stderr = out / "companion.stderr.log"
    companion_log = out / "companion.log"
    for path in (companion_stdout, companion_stderr, companion_log):
        write_exclusive(path, b"")
    stdout_handle = companion_stdout.open("r+b", buffering=0)
    stderr_handle = companion_stderr.open("r+b", buffering=0)
    companion_binary = Path(pre["matrix"]["companion_binary"])
    companion_env = {
        "HOME": str(tmp),
        "TMPDIR": str(tmp),
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    }
    companion_argv = [
        str(companion_binary),
        "--udid", UDID,
        "--grpc-domain-sock", str(socket_path),
        "--log-file-path", str(companion_log),
        "--terminate-offline", "true",
        "--only", "simulator",
    ]
    process = subprocess.Popen(companion_argv, stdout=stdout_handle, stderr=stderr_handle, env=companion_env, start_new_session=True)
    pgid = os.getpgid(process.pid)
    install_attempted = False
    uninstall_attempted = False
    companion_cleanup: dict[str, Any] | None = None
    socket_cleanup: dict[str, Any] | None = None
    socket_root_cleanup: dict[str, Any] | None = None
    failure: Exception | None = None
    receipts: dict[str, Any] = {"preflight": pre_receipt, "lease": lease_receipt}
    try:
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise TransactionError(f"companion exited before readiness: {process.returncode}")
            if os.path.lexists(socket_path):
                item = identity(socket_path)
                if item["type"] == "socket" and item["uid"] == os.getuid():
                    break
            time.sleep(0.1)
        else:
            raise TransactionError("companion socket readiness timed out")
        launch_receipt = publisher.json("companion-launch.json", {
            "schema": "learnfold-d0fb-private-companion-launch-v2",
            "transaction_id": transaction_id,
            "pid": process.pid,
            "pgid": pgid,
            "argv": companion_argv,
            "binary": identity(companion_binary, hash_regular=True),
            "socket": identity(socket_path),
            "socket_root": socket_root_item,
            "socket_probe": socket_probe,
            "sanitized_environment_keys": sorted(companion_env),
            "lease": lease_item,
        })
        receipts["companion_launch"] = launch_receipt

        idb_env = dict(companion_env)
        idb_env["PYTHONPATH"] = pre["matrix"]["idb_distribution"]
        idb_argv = [
            pre["matrix"]["idb_interpreter"], pre["matrix"]["idb_script"],
            "--companion", str(socket_path), "ui", "describe-all",
            "--udid", UDID, "--json", "--nested",
        ]
        calls = []
        for ordinal in (1, 2):
            result = run_capture(idb_argv, timeout=60, env=idb_env)
            if result["outcome"] != "returned" or result["exit"] != 0:
                raise TransactionError(f"preinstall idb call {ordinal} failed")
            parsed = parse_application(result["_stdout"])
            calls.append({**public_result(result), "ordinal": ordinal, "projection": parsed})
        gate_receipt = publisher.json("preinstall-private-idb-gate.json", {
            "schema": "learnfold-d0fb-private-idb-gate-v2",
            "transaction_id": transaction_id,
            "calls": calls,
            "companion_pid": process.pid,
            "companion_pgid": pgid,
            "socket": identity(socket_path),
            "lease": lease_item,
        })
        receipts["private_idb_gate"] = gate_receipt

        predecessor_intent = publisher.json("predecessor-retirement-intent.json", {
            "schema": "learnfold-predecessor-retirement-intent-v2",
            "transaction_id": transaction_id,
            "argv": ["xcrun", "simctl", "uninstall", UDID, BUNDLE_ID],
            "predecessor": pre["predecessor"],
            "companion_launch_sha256": launch_receipt["artifact"]["sha256"],
            "lease": lease_item,
        })
        receipts["predecessor_intent"] = predecessor_intent
        uninstall_attempted = True
        uninstall = run_capture(["xcrun", "simctl", "uninstall", UDID, BUNDLE_ID], timeout=180)
        predecessor_app_after = container("app")
        predecessor_data_after = container("data")
        if predecessor_app_after["present"] or predecessor_data_after["present"]:
            raise TransactionError("predecessor remains after the single uninstall attempt")
        retirement_receipt = publisher.json("predecessor-retirement-result.json", {
            "schema": "learnfold-predecessor-retirement-result-v2",
            "transaction_id": transaction_id,
            "intent_sha256": predecessor_intent["artifact"]["sha256"],
            "invocation_count": 1,
            "command": public_result(uninstall),
            "durable_state": {"app": predecessor_app_after, "data": predecessor_data_after, "both_absent": True},
            "accepted_by": "command-rc0-and-durable-absence" if uninstall["exit"] == 0 else "durable-absence-after-ambiguous-command",
            "companion_live": process.poll() is None,
            "lease_retained": os.path.lexists(lease),
        })
        receipts["predecessor_result"] = retirement_receipt

        install_intent = publisher.json("install-intent.json", {
            "schema": "learnfold-d0fb-final-install-intent-v2",
            "transaction_id": transaction_id,
            "argv": ["xcrun", "simctl", "install", UDID, str(APP)],
            "invocation_ordinal": 1,
            "bundle_id": BUNDLE_ID,
            "candidate_app": pre["matrix"]["candidate_app"],
            "predecessor_retirement_sha256": retirement_receipt["artifact"]["sha256"],
            "private_idb_gate_sha256": gate_receipt["artifact"]["sha256"],
            "lease": lease_item,
        })
        receipts["install_intent"] = install_intent
        use_boundary_bundle = bundle_hash(APP)
        use_boundary_executable = sha256_file(APP / pre["matrix"]["candidate_app"]["executable_name"])
        if use_boundary_bundle != pre["matrix"]["candidate_app"]["bundle_sha256"] or use_boundary_executable != pre["matrix"]["candidate_app"]["executable_sha256"]:
            raise TransactionError("candidate app changed at the install use boundary")
        install_attempted = True
        install = run_capture(["xcrun", "simctl", "install", UDID, str(APP)], timeout=600)
        installed_app = container("app")
        installed_data = container("data")
        if not installed_app["present"] or not installed_data["present"]:
            raise TransactionError("candidate app/data is absent after the single install attempt")
        installed_path = Path(installed_app["path"])
        installed_bundle = bundle_hash(installed_path)
        installed_executable = sha256_file(installed_path / pre["matrix"]["candidate_app"]["executable_name"])
        if installed_bundle != pre["matrix"]["candidate_app"]["bundle_sha256"] or installed_executable != pre["matrix"]["candidate_app"]["executable_sha256"]:
            raise TransactionError("installed app identity does not match the frozen candidate")
        install_receipt = publisher.json("install-result.json", {
            "schema": "learnfold-d0fb-final-install-result-v2",
            "transaction_id": transaction_id,
            "intent_sha256": install_intent["artifact"]["sha256"],
            "invocation_count": 1,
            "command": public_result(install),
            "use_boundary": {"bundle_sha256": use_boundary_bundle, "executable_sha256": use_boundary_executable},
            "accepted_by": "command-rc0-and-installed-identity" if install["exit"] == 0 else "installed-identity-after-ambiguous-command",
            "installed_app": {"container": identity(installed_path), "bundle_sha256": installed_bundle, "executable_sha256": installed_executable},
            "installed_data": {"container": identity(Path(installed_data["path"]))},
        })
        receipts["install_result"] = install_receipt

        second_app = container("app")
        second_data = container("data")
        processes = app_processes()
        if second_app["path"] != installed_app["path"] or second_data["path"] != installed_data["path"] or processes:
            raise TransactionError("postinstall container/process state is unstable")
        postinstall_receipt = publisher.json("postinstall-state.json", {
            "schema": "learnfold-d0fb-final-postinstall-v2",
            "transaction_id": transaction_id,
            "two_stable_container_reads": True,
            "first": {"app": installed_app, "data": installed_data},
            "second": {"app": second_app, "data": second_data},
            "app_processes": processes,
            "app_process_absent": True,
            "install_invocation_count": 1,
            "launch_invocation_count": 0,
            "canonical_absences": canonical_absences(),
        })
        if not all(item["absent"] for item in canonical_absences()):
            raise TransactionError("canonical acceptance output appeared during install")
        receipts["postinstall"] = postinstall_receipt
    except Exception as error:
        failure = error
    finally:
        try:
            companion_cleanup = stop_companion(process, pgid)
        except Exception as error:
            if failure is None:
                failure = error
            companion_cleanup = {"error": str(error), "reaped": False}
        stdout_handle.close()
        stderr_handle.close()
        try:
            if os.path.lexists(socket_path):
                socket_cleanup = unlink_owned_socket(socket_path, socket_root)
            else:
                socket_cleanup = {"before": None, "absent_after": True}
        except Exception as error:
            if failure is None:
                failure = error
            socket_cleanup = {"error": str(error), "absent_after": False}
        try:
            if socket_cleanup.get("absent_after") is True:
                socket_root_cleanup = remove_owned_socket_root(socket_root, socket_root_item)
            else:
                socket_root_cleanup = {"absent_after": False, "skipped": "socket-cleanup-failed"}
        except Exception as error:
            if failure is None:
                failure = error
            socket_root_cleanup = {"error": str(error), "absent_after": False}

    log_bindings = {}
    for path in (companion_stdout, companion_stderr, companion_log):
        raw = path.read_bytes()
        if SECRET_PATTERN.search(raw):
            if failure is None:
                failure = TransactionError(f"retained companion log contains secret-like material: {path.name}")
        log_bindings[path.name] = publisher.seal_existing(path)
    cleanup_receipt = publisher.json("companion-cleanup.json", {
        "schema": "learnfold-d0fb-private-companion-cleanup-v2",
        "transaction_id": transaction_id,
        "process_group": companion_cleanup,
        "socket": socket_cleanup,
        "socket_root": socket_root_cleanup,
        "logs": log_bindings,
        "lease_retained": os.path.lexists(lease),
        "lease_identity": identity(lease) if os.path.lexists(lease) else None,
        "install_attempted": install_attempted,
        "uninstall_attempted": uninstall_attempted,
    })
    receipts["companion_cleanup"] = cleanup_receipt

    if failure is not None:
        terminal = publisher.json("terminal-failure.json", {
            "schema": "learnfold-d0fb-final-transaction-failure-v2",
            "transaction_id": transaction_id,
            "error_type": type(failure).__name__,
            "error": str(failure),
            "install_attempted": install_attempted,
            "uninstall_attempted": uninstall_attempted,
            "no_retry_authorized": True,
            "lease_retained": os.path.lexists(lease),
            "receipts": receipts,
        })
        raise TransactionError(f"transaction failed; evidence={out}; terminal={terminal['artifact']['sha256']}: {failure}")

    installed_app = container("app")
    installed_data = container("data")
    if not installed_app["present"] or not installed_data["present"] or app_processes():
        raise TransactionError("handoff state changed before publication")
    absences = canonical_absences()
    if not all(item["absent"] for item in absences):
        raise TransactionError("canonical acceptance output appeared before handoff")
    handoff = publisher.json("acceptance-operator-handoff.json", {
        "schema": "learnfold-d0fb-final-operator-handoff-v2",
        "transaction_id": transaction_id,
        "created_at_utc": utc_now(),
        "next_authorized_role": "acceptance_operator",
        "matrix_root": str(MATRIX_ROOT),
        "sealed_authority_root": str(AUTHORITY),
        "simulator": pre["simulator"]["acceptance"],
        "historical_protected_simulator": pre["simulator"]["historical"],
        "bundle_id": BUNDLE_ID,
        "installed_app": {"container": identity(Path(installed_app["path"])), **pre["matrix"]["candidate_app"]},
        "installed_data": {"container": identity(Path(installed_data["path"]))},
        "app_process_absent": True,
        "app_unlaunched": True,
        "install_invocation_count": 1,
        "launch_invocation_count": 0,
        "lease_retained_for_acceptance": True,
        "lease_identity": identity(lease),
        "lease_token_sha256": lease_item["token_sha256"],
        "canonical_missing_nodes": absences,
        "transaction_script": pre["script"],
        "frozen_identities": pre["matrix"],
        "receipts": receipts,
    })
    return {
        "status": "passed",
        "transaction_id": transaction_id,
        "transaction_root": str(out),
        "handoff_path": handoff["artifact"]["path"],
        "handoff_sha256": handoff["artifact"]["sha256"],
        "lease_path": str(lease),
        "lease_inode": identity(lease)["inode"],
        "installed_app_container": installed_app["path"],
        "installed_data_container": installed_data["path"],
        "install_invocation_count": 1,
        "launch_invocation_count": 0,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--preflight-only", action="store_true")
    parser.add_argument("--close-failed-attempt", type=Path)
    args = parser.parse_args()
    signal_count = 0

    def handler(number: int, _frame: Any) -> None:
        nonlocal signal_count
        signal_count += 1
        raise SignalAbort(f"received signal {signal.Signals(number).name}; count={signal_count}")

    previous = {}
    for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        previous[number] = signal.getsignal(number)
        signal.signal(number, handler)
    try:
        if args.close_failed_attempt is not None:
            summary = close_failed_preinstall_attempt(args.close_failed_attempt)
        else:
            current = preflight()
        if args.close_failed_attempt is None and args.preflight_only:
            summary = {
                "status": "passed",
                "schema": current["schema"],
                "matrix_root": str(MATRIX_ROOT),
                "candidate_bundle_sha256": current["matrix"]["candidate_app"]["bundle_sha256"],
                "candidate_executable_sha256": current["matrix"]["candidate_app"]["executable_sha256"],
                "predecessor_bundle_sha256": current["predecessor"]["bundle_sha256"],
                "predecessor_process_count": len(current["predecessor"]["processes"]),
                "existing_lease_count": len(current["existing_leases"]),
                "canonical_missing_count": sum(1 for item in current["canonical_absences"] if item["absent"]),
            }
        elif args.close_failed_attempt is None:
            summary = execute_transaction(current)
        print(json.dumps(summary, sort_keys=True, separators=(",", ":")))
        return 0
    except Exception as error:
        print(json.dumps({"status": "failed", "error_type": type(error).__name__, "error": str(error)}, sort_keys=True, separators=(",", ":")), file=sys.stderr)
        return 1
    finally:
        for number, old in previous.items():
            signal.signal(number, old)


if __name__ == "__main__":
    raise SystemExit(main())
