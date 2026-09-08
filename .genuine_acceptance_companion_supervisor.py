#!/usr/bin/env python3
"""Own the private D0FB idb companion for one retained acceptance lease."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import signal
import stat
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any


TRANSACTION_ROOT = Path("/Users/Shared/LearnfoldD0FBFinalAcceptance-final2-20260824T131942Z-ed1ef27852f4")
HANDOFF = TRANSACTION_ROOT / "acceptance-operator-handoff.json"
SCRIPT = Path(__file__).resolve()
TXN_SCRIPT = Path("/Users/chirag13/development/litter-course/.final_acceptance_transaction_v2.py")
UDID = "D0FB9369-BFB4-4966-B677-2F42CDE0B218"
BUNDLE_ID = "com.chirag.learnfold"


class SupervisorError(RuntimeError):
    pass


def load_transaction_module() -> Any:
    spec = importlib.util.spec_from_file_location("learnfold_transaction", TXN_SCRIPT)
    if spec is None or spec.loader is None:
        raise SupervisorError("cannot load sealed transaction module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def verify_sidecar(path: Path) -> str:
    sidecar = path.with_name(path.name + ".sha256")
    if path.is_symlink() or sidecar.is_symlink() or not path.is_file() or not sidecar.is_file():
        raise SupervisorError(f"unsafe receipt pair: {path.name}")
    fields = sidecar.read_text(encoding="ascii").split()
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if len(fields) != 2 or fields[0] != actual or fields[1] != path.name:
        raise SupervisorError(f"receipt sidecar mismatch: {path.name}")
    return actual


def sealed_script_identity(txn: Any) -> dict[str, Any]:
    item = txn.identity(SCRIPT, hash_regular=True)
    if item["type"] != "regular" or item["uid"] != os.getuid() or item["mode"] != "0o0444" or item["flags"] & 2 != 2:
        raise SupervisorError("acceptance companion supervisor is not sealed")
    return item


def validate_handoff(txn: Any) -> tuple[dict[str, Any], dict[str, Any]]:
    handoff_sha = verify_sidecar(HANDOFF)
    handoff = json.loads(HANDOFF.read_text(encoding="utf-8"))
    if handoff.get("schema") != "learnfold-d0fb-final-operator-handoff-v2" or handoff.get("install_invocation_count") != 1 or handoff.get("launch_invocation_count") != 0:
        raise SupervisorError("operator handoff contract mismatch")
    if handoff.get("app_unlaunched") is not True or handoff.get("app_process_absent") is not True:
        raise SupervisorError("operator handoff is not at the first-launch boundary")
    for sidecar in sorted(TRANSACTION_ROOT.glob("*.sha256")):
        verify_sidecar(sidecar.with_name(sidecar.name.removesuffix(".sha256")))
    lease = Path(handoff["lease_identity"]["path"])
    lease_item = txn.identity(lease, hash_regular=True)
    for key in ("path", "realpath", "type", "dev", "inode", "uid", "mode", "bytes"):
        if lease_item[key] != handoff["lease_identity"][key]:
            raise SupervisorError("retained lease identity mismatch")
    if lease_item["sha256"] != handoff["lease_token_sha256"]:
        raise SupervisorError("retained lease token hash mismatch")
    app = txn.container("app")
    data = txn.container("data")
    if not app["present"] or not data["present"] or txn.app_processes():
        raise SupervisorError("installed app boundary changed before adoption")
    if app["path"] != handoff["installed_app"]["container"]["path"] or data["path"] != handoff["installed_data"]["container"]["path"]:
        raise SupervisorError("installed container identity changed before adoption")
    app_path = Path(app["path"])
    if txn.bundle_hash(app_path) != handoff["installed_app"]["bundle_sha256"] or txn.sha256_file(app_path / "Litter") != handoff["installed_app"]["executable_sha256"]:
        raise SupervisorError("installed app bytes changed before adoption")
    if not all(item["absent"] for item in txn.canonical_absences()):
        raise SupervisorError("canonical acceptance outputs already exist")
    return handoff, {
        "handoff_sha256": handoff_sha,
        "lease": lease_item,
        "app": app,
        "data": data,
        "app_bundle_sha256": handoff["installed_app"]["bundle_sha256"],
        "app_executable_sha256": handoff["installed_app"]["executable_sha256"],
    }


def run() -> int:
    txn = load_transaction_module()
    handoff, adoption = validate_handoff(txn)
    script_item = sealed_script_identity(txn)
    publisher = txn.Publisher(TRANSACTION_ROOT)
    token = uuid.uuid4().hex[:12]
    socket_root = Path("/Users/Shared") / f"LFA-{token}"
    os.mkdir(socket_root, 0o700)
    txn.fsync_dir(socket_root.parent)
    socket_root_item = txn.identity(socket_root)
    socket_path = socket_root / "fb-idb.sock"
    socket_probe = txn.probe_unix_socket_path(socket_path, socket_root)
    tmp = TRANSACTION_ROOT / "acceptance-companion-tmp"
    if not os.path.lexists(tmp):
        os.mkdir(tmp, 0o700)
        txn.fsync_dir(TRANSACTION_ROOT)
    elif txn.identity(tmp)["type"] != "directory" or txn.identity(tmp)["mode"] != "0o0700":
        raise SupervisorError("acceptance companion temp root is unsafe")
    stdout_path = TRANSACTION_ROOT / "acceptance-companion.stdout.log"
    stderr_path = TRANSACTION_ROOT / "acceptance-companion.stderr.log"
    log_path = TRANSACTION_ROOT / "acceptance-companion.log"
    for path in (stdout_path, stderr_path, log_path):
        txn.write_exclusive(path, b"")
    stdout_handle = stdout_path.open("r+b", buffering=0)
    stderr_handle = stderr_path.open("r+b", buffering=0)
    binary = Path(handoff["frozen_identities"]["companion_binary"])
    if txn.sha256_file(binary) != handoff["frozen_identities"]["companion_binary_sha256"]:
        raise SupervisorError("companion binary changed before launch")
    env = {
        "HOME": str(tmp),
        "TMPDIR": str(tmp),
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    }
    argv = [
        str(binary), "--udid", UDID,
        "--grpc-domain-sock", str(socket_path),
        "--log-file-path", str(log_path),
        "--terminate-offline", "true",
        "--only", "simulator",
    ]
    process: subprocess.Popen[bytes] | None = None
    pgid: int | None = None
    stop_signal: str | None = None

    def request_stop(number: int, _frame: Any) -> None:
        nonlocal stop_signal
        stop_signal = signal.Signals(number).name

    previous = {number: signal.getsignal(number) for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)}
    for number in previous:
        signal.signal(number, request_stop)
    launch_receipt: dict[str, Any] | None = None
    failure: Exception | None = None
    try:
        process = subprocess.Popen(argv, stdout=stdout_handle, stderr=stderr_handle, env=env, start_new_session=True)
        pgid = os.getpgid(process.pid)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if stop_signal:
                raise SupervisorError(f"stop requested before readiness: {stop_signal}")
            if process.poll() is not None:
                raise SupervisorError(f"acceptance companion exited before readiness: {process.returncode}")
            if os.path.lexists(socket_path):
                item = txn.identity(socket_path)
                if item["type"] == "socket" and item["uid"] == os.getuid():
                    break
            time.sleep(0.1)
        else:
            raise SupervisorError("acceptance companion readiness timed out")
        launch_receipt = publisher.json("acceptance-companion-launch.json", {
            "schema": "learnfold-acceptance-private-companion-launch-v1",
            "created_at_utc": txn.utc_now(),
            "supervisor": script_item,
            "adoption": adoption,
            "pid": process.pid,
            "pgid": pgid,
            "argv": argv,
            "binary": txn.identity(binary, hash_regular=True),
            "socket": txn.identity(socket_path),
            "socket_root": socket_root_item,
            "socket_probe": socket_probe,
            "environment_keys": sorted(env),
            "canonical_absences": txn.canonical_absences(),
        })
        print(json.dumps({
            "status": "ready",
            "pid": process.pid,
            "pgid": pgid,
            "socket": str(socket_path),
            "launch_receipt_sha256": launch_receipt["artifact"]["sha256"],
        }, sort_keys=True, separators=(",", ":")), flush=True)
        while not stop_signal:
            line = sys.stdin.readline()
            if line == "":
                time.sleep(0.2)
                continue
            if line.strip().lower() == "stop":
                stop_signal = "operator-stop"
    except Exception as error:
        failure = error
    finally:
        cleanup: dict[str, Any]
        try:
            if process is not None and pgid is not None:
                cleanup = txn.stop_companion(process, pgid)
            else:
                cleanup = {"before": [], "after_term": [], "after": [], "leader_returncode": None, "reaped": True, "not_started": True}
        except Exception as error:
            cleanup = {"error": str(error), "reaped": False}
            if failure is None:
                failure = error
        stdout_handle.close()
        stderr_handle.close()
        try:
            socket_cleanup = txn.unlink_owned_socket(socket_path, socket_root) if os.path.lexists(socket_path) else {"before": None, "absent_after": True}
        except Exception as error:
            socket_cleanup = {"error": str(error), "absent_after": False}
            if failure is None:
                failure = error
        try:
            root_cleanup = txn.remove_owned_socket_root(socket_root, socket_root_item) if socket_cleanup.get("absent_after") is True else {"absent_after": False, "skipped": "socket-cleanup-failed"}
        except Exception as error:
            root_cleanup = {"error": str(error), "absent_after": False}
            if failure is None:
                failure = error
        logs: dict[str, Any] = {}
        for path in (stdout_path, stderr_path, log_path):
            raw = path.read_bytes()
            if txn.SECRET_PATTERN.search(raw) and failure is None:
                failure = SupervisorError(f"acceptance companion log contains secret-like material: {path.name}")
            logs[path.name] = publisher.seal_existing(path)
        cleanup_receipt = publisher.json("acceptance-companion-cleanup.json", {
            "schema": "learnfold-acceptance-private-companion-cleanup-v1",
            "created_at_utc": txn.utc_now(),
            "launch_receipt_sha256": launch_receipt["artifact"]["sha256"] if launch_receipt else None,
            "stop_reason": stop_signal,
            "process_group": cleanup,
            "socket": socket_cleanup,
            "socket_root": root_cleanup,
            "logs": logs,
            "lease_retained": os.path.lexists(Path(handoff["lease_identity"]["path"])),
        })
        print(json.dumps({
            "status": "stopped" if failure is None else "failed",
            "error": str(failure) if failure else None,
            "cleanup_receipt_sha256": cleanup_receipt["artifact"]["sha256"],
        }, sort_keys=True, separators=(",", ":")), flush=True)
        for number, old in previous.items():
            signal.signal(number, old)
    return 0 if failure is None else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("supervise",))
    parser.parse_args()
    try:
        return run()
    except Exception as error:
        print(json.dumps({"status": "failed", "error": str(error)}, sort_keys=True, separators=(",", ":")), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
