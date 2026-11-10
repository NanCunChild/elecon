#!/usr/bin/env python3
"""Local/ADB client for ADR-100. Python stdlib only; no school requests."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
import uuid


class Files:
    def __init__(self, args):
        self.local = Path(args.local) if args.local else None
        self.adb = [args.adb] + (["-s", args.serial] if args.serial else [])
        self.package = args.package
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_.]*", self.package):
            raise ValueError("invalid application ID")
        self.root = "files/debug-tools"

    def shell(self, script, data=None):
        command = shlex.join(["run-as", self.package, "sh", "-c", script])
        result = subprocess.run(self.adb + ["shell", command], input=data,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode:
            raise RuntimeError("ADB run-as failed: use a debuggable APK and select the device/package")
        return result.stdout

    def read(self, name):
        if self.local:
            return (self.local / name).read_bytes()
        return self.shell("cat " + shlex.quote(f"{self.root}/{name}"))

    def remove(self, name):
        if self.local:
            (self.local / name).unlink(missing_ok=True)
        else:
            self.shell("rm -f " + shlex.quote(f"{self.root}/{name}"))

    def submit(self, name, data):
        if self.local:
            target = self.local / "inbox" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            temporary = target.with_suffix(".tmp")
            temporary.write_bytes(data)
            os.replace(temporary, target)
        else:
            target = shlex.quote(f"{self.root}/inbox/{name}")
            temporary = shlex.quote(f"{self.root}/inbox/{name}.tmp")
            self.shell(f"mkdir -p {self.root}/inbox && cat > {temporary} && mv {temporary} {target}", data)


def read_package(path):
    text = path.read_bytes().decode("utf-8")
    if len(text.encode("utf-8")) > 1024 * 1024:
        raise ValueError("package exceeds 1 MiB")
    package = json.loads(text)
    if package.get("format") != "elecon-script/1":
        raise ValueError("only elecon-script/1 packages are supported; V1 is separate")
    package_id = package["manifest"]["id"]
    if not isinstance(package_id, str):
        raise ValueError("package ID must be a string")
    return text, package_id


def request(files, args, operation, **fields):
    status = json.loads(files.read("status.json"))
    profile = args.profile or status["profileId"]
    if profile != status["profileId"] or status["locked"]:
        raise RuntimeError("select and unlock the target Profile in the foreground app first")
    request_id = uuid.uuid4().hex
    data = {"version": 1, "profileId": profile, "operation": operation, **fields}
    files.submit(request_id + ".json", json.dumps(data, ensure_ascii=False).encode("utf-8"))
    deadline = time.monotonic() + args.timeout
    result_name = f"results/{request_id}.json"
    while time.monotonic() < deadline:
        try:
            result = json.loads(files.read(result_name))
        except (FileNotFoundError, RuntimeError):
            time.sleep(0.25)
            continue
        files.remove(result_name)
        if result.get("result") != "ok":
            raise RuntimeError(f"{result.get('result', 'invalid_result')} ({request_id}); check package, version, Profile and debug flag")
        print(f"{operation}: ok ({request_id})", file=sys.stderr)
        return
    raise RuntimeError(f"result unknown: {request_id}; inspect processing/results before retrying; keep app in foreground")


def put(files, args, text):
    request(files, args, "upsert", package=text,
            sha256=hashlib.sha256(text.encode("utf-8")).hexdigest())


def sync(files, args):
    previous = {}
    if not Path(args.directory).is_dir():
        raise ValueError("sync directory does not exist")
    # Pin the entire watch session to one Profile, never follow UI switches.
    args.profile = args.profile or json.loads(files.read("status.json"))["profileId"]
    while True:
        current = {}
        try:
            for path in sorted(Path(args.directory).glob("*.elecon.json")):
                text, package_id = read_package(path)
                if package_id in current:
                    raise ValueError("duplicate package IDs in sync directory")
                current[package_id] = text
        except (ValueError, KeyError, OSError):
            if not args.watch:
                raise
            # Editors/builders may briefly expose incomplete JSON. Keep the
            # previous successful snapshot, including deletion ownership.
            print("package scan incomplete; waiting for valid files", file=sys.stderr)
            time.sleep(1)
            continue
        for package_id, text in current.items():
            if previous.get(package_id) != text:
                put(files, args, text)
        # Only remove IDs successfully synchronized by this invocation.
        for package_id in previous.keys() - current.keys():
            request(files, args, "remove", packageId=package_id)
        previous = current
        if not args.watch:
            return
        time.sleep(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--serial", "-s")
    parser.add_argument("--package", default="com.ncclab.elecon")
    parser.add_argument("--local", help="desktop application-support/debug-tools directory (skip ADB)")
    parser.add_argument("--profile", help="pin target Profile ID; defaults to current status")
    parser.add_argument("--timeout", type=float, default=15)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status")
    upload = commands.add_parser("put", help="add or replace one packaged Adapter, including same-version edits")
    upload.add_argument("file", type=Path)
    remove = commands.add_parser("remove")
    remove.add_argument("package_id")
    directory = commands.add_parser("sync", help="synchronize *.elecon.json; watch also detects removal")
    directory.add_argument("directory")
    directory.add_argument("--watch", action="store_true")
    logs = commands.add_parser("logs", help="export every retained complete JSONL record, oldest first")
    logs.add_argument("--output", type=Path)
    args = parser.parse_args()
    files = Files(args)
    if args.command == "status":
        print(json.dumps(json.loads(files.read("status.json")), ensure_ascii=False, indent=2))
    elif args.command == "put":
        text, _ = read_package(args.file)
        put(files, args, text)
    elif args.command == "remove":
        request(files, args, "remove", packageId=args.package_id)
    elif args.command == "sync":
        sync(files, args)
    elif args.command == "logs":
        chunks = []
        for index in [3, 2, 1, 0]:
            name = "logs/dev-log.jsonl" + (f".{index}" if index else "")
            try:
                chunks.append(files.read(name))
            except (FileNotFoundError, RuntimeError):
                if index == 0:
                    raise RuntimeError("debug log unavailable; start a debug APK first")
        output = b"".join(chunks)
        if args.output:
            args.output.write_bytes(output)
        else:
            sys.stdout.buffer.write(output)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except (ValueError, KeyError, OSError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
