#!/usr/bin/env python3
"""Source-bound Process-Control native macOS qualification."""
import argparse
from datetime import datetime, timezone
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
LIMIT = 65536
EXPORT_LIMIT = 32 * 1024 * 1024
REPOSITORY = "immateria/Native-Kernel.cr"


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def load_dependency(path):
    try:
        value = json.loads(Path(path).read_text())
        if (set(value) != {"schema", "repository", "ref"} or value["schema"] != 1
                or value["repository"] != REPOSITORY
                or not isinstance(value["ref"], str)
                or not re.fullmatch(r"[0-9a-f]{40}", value["ref"])
                or value["ref"] == "0" * 40):
            raise ValueError("Native-Kernel requires its explicit repository and nonzero 40-hex commit")
        return value
    except (OSError, TypeError, json.JSONDecodeError) as error:
        raise ValueError("Invalid Native-Kernel manifest: " + str(error)) from error


def validate_dependency(manifest, checkout):
    if checkout.get("revision") != manifest["ref"]:
        raise ValueError("Native-Kernel checkout differs from the required manifest commit")


def verify_checkout_pin(dependency, manifest):
    # Validate before importing any code from the dependency. This fixed Git
    # query has a 40-byte successful result and cannot launch owned descendants.
    result = subprocess.run(["git", "-C", str(dependency), "rev-parse", "--verify", "HEAD^{commit}"],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=20)
    revision = result.stdout.strip()
    if result.returncode != 0 or not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Cannot resolve exact Native-Kernel checkout revision")
    validate_dependency(manifest, {"revision": revision})


def source_identity(root):
    root = Path(root)
    files = set()
    for name in ("src", "native", "scripts", "spec", "ci", "tests", "docs", "examples", ".github/workflows"):
        directory = root / name
        if directory.is_dir():
            files.update(path for path in directory.rglob("*")
                         if path.is_file() and "__pycache__" not in path.parts)
    for name in ("shard.yml", "Makefile", "AGENTS.md", "README.md"):
        if (root / name).is_file():
            files.add(root / name)
    return {path.relative_to(root).as_posix(): sha256_file(path) for path in sorted(files)}


def spec_completion(result):
    if result.get("status") != "passed" or result.get("exit_code") != 0 or result.get("output_truncated"):
        raise ValueError("Complete spec execution did not finish successfully within its bounds")
    summaries = re.findall(r"^(\d+) examples?, (\d+) failures?, (\d+) errors?, (\d+) pending\s*$",
                           result.get("stdout", ""), re.M)
    if len(summaries) != 1 or int(summaries[0][0]) <= 0 or any(int(value) for value in summaries[0][1:]):
        raise ValueError("Complete spec execution lacks one nonempty zero-failure/error/pending summary")
    return int(summaries[0][0])


def validate_helper_proof(helper, dependency_sources, compiler, architecture):
    helper = Path(helper)
    proof = json.loads(Path(str(helper) + ".audit.json").read_text())
    expected_sources = {name: digest for name, digest in dependency_sources.items() if name.startswith("src/")}
    target = {"arm64": "aarch64-darwin", "x86_64": "x86_64-darwin"}[architecture]
    if (not helper.is_file() or proof.get("compiler", "").strip() != compiler.strip()
            or proof.get("target") != target or proof.get("native_symbols") != []
            or not proof.get("assembly") or proof.get("dependency_sources") != expected_sources
            or not re.fullmatch(r"[0-9a-f]{64}", proof.get("source", ""))):
        raise ValueError("Helper audit does not bind the compiler, raw target and complete dependency sources")
    for name, suffix in (("ir", ".ll"), ("development_ir", ".development.ll")):
        if proof.get(name) != sha256_file(Path(str(helper) + suffix)):
            raise ValueError("Helper " + name + " digest differs from audited bytes")
    return proof


def load_native_driver(dependency):
    path = Path(dependency) / "scripts/ci/runner.py"
    spec = importlib.util.spec_from_file_location("pinned_native_kernel_ci", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def export_evidence(output, receipt):
    output = Path(output)
    bundle = output / "export"
    bundle.mkdir(parents=True, exist_ok=True)
    files = {}
    total = 0
    if receipt.get("status") == "passed":
        helper = output / "helper"
        if not helper.is_file() or sha256_file(helper) != receipt.get("helper_sha256"):
            raise ValueError("Audited helper changed before export")
        proof = validate_helper_proof(helper, receipt["repositories"]["native-kernel"]["sources"],
                                      receipt["compiler"]["description"], receipt["profile_definition"]["architecture"])
        if proof != receipt.get("helper_proof_after"):
            raise ValueError("Audited helper changed before export")

    def include(path, relative, compressed=False):
        nonlocal total
        target = bundle / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if compressed:
            with path.open("rb") as source, gzip.open(target, "wb", compresslevel=9) as destination:
                shutil.copyfileobj(source, destination)
        else:
            shutil.copyfile(path, target)
        total += target.stat().st_size
        if total > EXPORT_LIMIT:
            target.unlink()
            raise ValueError("Export exceeds 32 MiB bound")
        files[relative] = sha256_file(target)
        return target

    for path in sorted((output / "logs").glob("*")):
        if path.is_file() and not path.is_symlink():
            if path.stat().st_size > LIMIT:
                raise ValueError("Log exceeds output bound: " + path.name)
            include(path, "logs/" + path.name)
    helper = output / "helper"
    for suffix in ("", ".audit.json"):
        path = Path(str(helper) + suffix)
        if path.is_file():
            target = include(path, "helper/helper" + suffix)
            if not suffix:
                target.chmod(0o700)
    # Keep rejected audit IR too; object files and compiler caches never enter export.
    for path in sorted(output.glob("helper*.ll")):
        include(path, "ir/" + path.name + ".gz", compressed=True)
    receipt["bundle_files"] = files
    receipt["bundle_bytes_without_receipt"] = total
    write_json(bundle / "receipt.json", receipt)


def snapshot(runner, name, root):
    root = Path(root)
    revision = runner.stage("revision-" + name, ["git", "-C", str(root), "rev-parse", "HEAD"], timeout=20)["stdout"].strip()
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Invalid exact revision for " + name)
    status = runner.stage("status-" + name, ["git", "-C", str(root), "status", "--porcelain", "--untracked-files=all"], timeout=20)["stdout"]
    if (os.environ.get("CI") or os.environ.get("GITHUB_ACTIONS")) and status:
        raise ValueError("CI source checkout is dirty: " + name)
    return {"revision": revision, "git_status": status, "sources": source_identity(root)}


def link_dependency(root, dependency):
    library = root / "lib"
    library.mkdir(exist_ok=True)
    link = library / "native-kernel"
    if link.is_symlink():
        if link.resolve() != dependency:
            raise ValueError("Existing native-kernel link resolves to a different checkout")
    elif link.exists():
        raise ValueError("Refusing to replace an existing native-kernel library")
    else:
        link.symlink_to(dependency, target_is_directory=True)


def qualify(args, receipt):
    root = ROOT.resolve()
    dependency = Path(args.dependency).expanduser().resolve()
    output = Path(args.output).expanduser().resolve()
    if output == dependency or output.is_relative_to(dependency):
        raise ValueError("Output must be outside Native-Kernel")
    if dependency != root.parent / "native-kernel":
        raise ValueError("Native-Kernel must be the explicit sibling checkout")
    manifest = load_dependency(root / "ci/native-kernel.json")
    receipt["dependency_manifest"] = manifest
    verify_checkout_pin(dependency, manifest)
    native = load_native_driver(dependency)
    # This pinned driver owns bounded group cleanup and native host/compiler identity.
    runner = native.Runner(args, root=dependency)
    runner.receipt = receipt
    runner.environment.update(PROCESS_CONTROL_HELPER=str(output / "helper"),
                              XDG_CACHE_HOME=str(output / "helper-cache"))
    setup_path = output / "setup.json"
    if os.environ.get("GITHUB_ACTIONS"):
        setup = json.loads(setup_path.read_text())
        if [stage.get("name") for stage in setup] != ["setup-dependencies", "setup-verify"] or not native.all_passed(setup):
            raise ValueError("Required bounded dependency/compiler setup did not pass")
        receipt["stages"].extend(setup)
    before = {}
    receipt["repositories"] = before
    try:
        before["process-control"] = snapshot(runner, "process-control-before", root)
        before["native-kernel"] = snapshot(runner, "native-kernel-before", dependency)
        validate_dependency(manifest, before["native-kernel"])
        runner.preflight()
        compiler = runner.identify_compiler()
        if receipt["compiler"]["version"] != args.compiler_version:
            raise ValueError("Actual compiler differs from the requested matrix version")
        receipt["native_configuration"] = receipt.pop("configuration")
        receipt["consumer_spawn"] = "complete-suite-and-held-session-target"
        runner.root = root
        runner.stage("ignored-library", ["git", "check-ignore", "lib/native-kernel"], timeout=20)
        link_dependency(root, dependency)
        runner.stage("python-tests", [sys.executable, "-B", "-m", "unittest", "discover", "-s", "tests"], timeout=60)
        runner.stage("format", [compiler, "tool", "format", "--check", "src", "spec", "scripts", "examples", "native"], timeout=60)
        paths = runner.stage("compiler-library-paths", [compiler, "env", "CRYSTAL_PATH"], timeout=20)["stdout"].strip().split(":")
        runner.environment["CRYSTAL_PATH"] = ":".join([str(dependency / "src")] + [str((root / path).resolve()) for path in paths])
        runner.stage("build-helper", [compiler, "run", "--single-module", "scripts/build-helper.cr", "--",
                                       "--compiler", compiler, str(output / "helper")], timeout=300)
        receipt["helper_proof"] = validate_helper_proof(output / "helper", before["native-kernel"]["sources"],
                                                        receipt["compiler"]["description"], runner.profile["architecture"])
        receipt["helper_sha256"] = sha256_file(output / "helper")
        runner.audit_executable("helper", output / "helper")
        entry_source, spec_files = native.spec_runner_source(root, output)
        entry = output / "spec-runner.cr"
        entry.write_text(entry_source)
        receipt["spec_entry"] = {"sha256": sha256_file(entry), "files": spec_files,
                                  "sources": {name: before["process-control"]["sources"][name] for name in spec_files}}
        executable = output / "spec-runner"
        runner.stage("build-spec", [compiler, "build", "--single-module", "--error-on-warnings", str(entry), "-o", str(executable)], timeout=300)
        architectures = runner.stage("architecture-spec", ["xcrun", "lipo", "-archs", str(executable)], timeout=20)["stdout"].strip().split()
        if architectures != [runner.profile["architecture"]]:
            raise ValueError("Actual spec executable architecture differs from the native profile")
        receipt["spec_executable"] = {"sha256": sha256_file(executable), "architectures": architectures}
        result = runner.stage("spec", [str(executable), "--no-color"], timeout=300)
        receipt["completed_examples"] = spec_completion(result)
        if sha256_file(output / "helper") != receipt["helper_sha256"]:
            raise ValueError("Audited helper changed during complete suite execution")
        receipt["helper_proof_after"] = validate_helper_proof(output / "helper", before["native-kernel"]["sources"],
                                                              receipt["compiler"]["description"], runner.profile["architecture"])
        if receipt["helper_proof_after"] != receipt["helper_proof"]:
            raise ValueError("Helper audit changed during complete suite execution")
    finally:
        after = {}
        receipt["repositories_after"] = after
        for name, checkout in (("process-control", root), ("native-kernel", dependency)):
            after[name] = snapshot(runner, name + "-after", checkout)
        receipt["source_unchanged"] = before == after
        if not receipt["source_unchanged"]:
            raise ValueError("Source, configuration or exact revisions changed during qualification")
        validate_dependency(manifest, after["native-kernel"])
    if not receipt.get("completed_examples") or not native.all_passed(receipt["stages"]):
        raise ValueError("Qualification lacks complete passing evidence")


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="mode", required=True)
    dependency = subparsers.add_parser("dependency")
    dependency.add_argument("--manifest", default=str(ROOT / "ci/native-kernel.json"))
    dependency.add_argument("--output", required=True, help="GitHub step output file")
    setup = subparsers.add_parser("setup")
    setup.add_argument("operation", choices=("dependencies", "verify"))
    setup.add_argument("--profile", required=True)
    setup.add_argument("--compiler-version", choices=("1.10.0", "1.22.2"), required=True)
    setup.add_argument("--output", required=True)
    setup.add_argument("--dependency", default=str(ROOT.parent / "native-kernel"))
    for mode in ("qualify", "record-failure"):
        sub = subparsers.add_parser(mode)
        sub.add_argument("--profile", required=True)
        sub.add_argument("--output", required=True)
        if mode == "qualify":
            sub.add_argument("--compiler", required=True)
            sub.add_argument("--compiler-version", choices=("1.10.0", "1.22.2"), required=True)
            sub.add_argument("--compiler-binary")
            sub.add_argument("--dependency", default=str(ROOT.parent / "native-kernel"))
            sub.set_defaults(allow_translation=False)
        else:
            sub.add_argument("--reason", required=True)
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    if args.mode == "dependency":
        try:
            manifest = load_dependency(args.manifest)
            with Path(args.output).open("a") as stream:
                stream.write("repository=" + manifest["repository"] + "\nref=" + manifest["ref"] + "\n")
            return 0
        except Exception as error:
            print(str(error), file=sys.stderr)
            return 1
    output = Path(args.output).expanduser().resolve()
    # Reject every source-tree destination before mkdir or failure export.
    # record-failure has no dependency option but must protect the same sibling.
    root = ROOT.resolve()
    dependency = Path(getattr(args, "dependency", root.parent / "native-kernel")).expanduser().resolve()
    roots = (root, (root.parent / "native-kernel").resolve(), dependency)
    if any(output == source or output.is_relative_to(source) for source in roots):
        print("Evidence output must be outside both source checkouts", file=sys.stderr)
        return 1
    output.mkdir(parents=True, exist_ok=True)
    receipt = {"schema": 1, "mode": args.mode, "profile": args.profile, "status": "incomplete",
               "started_at": datetime.now(timezone.utc).isoformat(), "stages": [],
               "translation_exception": False, "scope": "native process core; no group controller or containment claim"}
    receipt["workflow"] = {name: value for name, value in os.environ.items()
                           if name in ("GITHUB_REPOSITORY", "GITHUB_SHA", "GITHUB_WORKFLOW_SHA", "GITHUB_RUN_ID",
                                       "GITHUB_RUN_ATTEMPT", "GITHUB_REF", "RUNNER_OS", "RUNNER_ARCH", "ImageVersion")}
    try:
        if args.mode == "setup":
            dependency = Path(args.dependency).expanduser().resolve()
            if dependency != ROOT.parent / "native-kernel" or output == dependency or output.is_relative_to(dependency):
                raise ValueError("Setup requires the sibling Native-Kernel and external output")
            manifest = load_dependency(ROOT / "ci/native-kernel.json")
            receipt["dependency_manifest"] = manifest
            verify_checkout_pin(dependency, manifest)
            native = load_native_driver(dependency)
            command = ["bash", str(dependency / "scripts/ci/setup.sh"), args.operation,
                       args.profile, args.compiler_version]
            result = native.run_bounded(command, output / "logs" / ("setup-" + args.operation),
                                        timeout=420, cwd=ROOT)
            result["name"] = "setup-" + args.operation
            if result["output_truncated"]:
                result["status"] = "failed"
            setup_path = output / "setup.json"
            setup = json.loads(setup_path.read_text()) if setup_path.is_file() else []
            setup.append(result)
            write_json(setup_path, setup)
            receipt["stages"] = setup
            if result["status"] == "passed":
                return 0
            raise ValueError("Bounded setup failed: " + args.operation)
        if args.mode == "record-failure":
            existing = output / "receipt.json"
            if existing.is_file():
                receipt = json.loads(existing.read_text())
            raise ValueError(args.reason)
        if (output / "receipt.json").exists():
            raise ValueError("Output already contains a receipt")
        qualify(args, receipt)
        receipt["status"] = "passed"
    except BaseException as error:
        receipt["status"] = "incomplete" if args.mode == "record-failure" else "failed"
        receipt["error"] = str(error)
        print("Qualification did not pass: " + str(error), file=sys.stderr)
    receipt["finished_at"] = datetime.now(timezone.utc).isoformat()
    try:
        export_evidence(output, receipt)
    except Exception as error:
        receipt["status"] = "failed"
        receipt["export_error"] = str(error)
        write_json(output / "export/receipt.json", receipt)
    write_json(output / "receipt.json", receipt)
    return 0 if receipt["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
