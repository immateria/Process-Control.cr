"""Consumer qualification contracts; no native process churn in unit tests."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/ci/macos.py"


class ConsumerCI(unittest.TestCase):
    def module(self):
        self.assertTrue(SCRIPT.is_file(), "Consumer qualification driver is missing")
        spec = importlib.util.spec_from_file_location("consumer_macos_ci", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def function(self, name):
        function = getattr(self.module(), name, None)
        self.assertTrue(callable(function), "Missing consumer contract: " + name)
        return function

    def test_dependency_requires_exact_commit_and_repository(self):
        load = self.function("load_dependency")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "native-kernel.json"
            for ref in ("main", "", "a" * 39, "A" * 40, "0" * 40):
                path.write_text(json.dumps({"schema": 1, "repository": "immateria/Native-Kernel.cr", "ref": ref}))
                with self.assertRaises(ValueError):
                    load(path)
            path.write_text(json.dumps({"schema": 1, "repository": "immateria/Native-Kernel.cr", "ref": "ab" * 20}))
            self.assertEqual(load(path)["ref"], "ab" * 20)
            path.write_text(json.dumps({"schema": 1, "repository": "other/repository", "ref": "ab" * 20}))
            with self.assertRaises(ValueError):
                load(path)

    def test_wrong_checkout_revision_is_refused(self):
        validate = self.function("validate_dependency")
        manifest = {"repository": "immateria/Native-Kernel.cr", "ref": "ab" * 20}
        with self.assertRaises(ValueError):
            validate(manifest, {"revision": "cd" * 20})
        validate(manifest, {"revision": "ab" * 20})

    def test_driver_is_not_imported_before_dependency_pin_validation(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as directory:
            args = module.parse_args(["qualify", "--profile", "macos-15-arm64", "--compiler", "crystal",
                                      "--compiler-version", "1.22.2", "--output", directory])
            with patch.object(module, "load_dependency", return_value={"repository": "immateria/Native-Kernel.cr", "ref": "ab" * 20}):
                with patch.object(module, "load_native_driver", side_effect=AssertionError("Imported an unvalidated dependency")):
                    with self.assertRaisesRegex(ValueError, "checkout differs"):
                        module.qualify(args, {"stages": []})

    def test_native_helper_source_and_configuration_changes_are_observed(self):
        identity = self.function("source_identity")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "native").mkdir()
            (root / "ci").mkdir()
            (root / "lib").mkdir()
            (root / "native/helper.cr").write_text("before")
            (root / "ci/native-kernel.json").write_text("before")
            (root / "lib/ignored").write_text("ignored")
            before = identity(root)
            self.assertEqual(set(before), {"native/helper.cr", "ci/native-kernel.json"})
            (root / "native/helper.cr").write_text("after")
            (root / "ci/native-kernel.json").write_text("after")
            after = identity(root)
            self.assertNotEqual(before["native/helper.cr"], after["native/helper.cr"])
            self.assertNotEqual(before["ci/native-kernel.json"], after["ci/native-kernel.json"])

    def test_complete_suite_requires_one_nonempty_zero_failure_summary(self):
        completion = self.function("spec_completion")
        result = {"status": "passed", "exit_code": 0, "output_truncated": False,
                  "stdout": "...\nFinished in 1.2 seconds\n119 examples, 0 failures, 0 errors, 0 pending\n", "stderr": ""}
        self.assertEqual(completion(result), 119)
        for output in ("", "0 examples, 0 failures, 0 errors, 0 pending\n",
                       "119 examples, 1 failures, 0 errors, 0 pending\n",
                       "119 examples, 0 failures, 1 errors, 0 pending\n",
                       "119 examples, 0 failures, 0 errors, 1 pending\n",
                       result["stdout"] * 2):
            with self.assertRaises(ValueError):
                completion(dict(result, stdout=output))
        for patch in ({"status": "timed_out"}, {"exit_code": 2}, {"output_truncated": True}):
            with self.assertRaises(ValueError):
                completion(dict(result, **patch))

    def test_helper_proof_binds_both_ir_modes_and_dependency_sources(self):
        validate = self.function("validate_helper_proof")
        module = self.module()
        with tempfile.TemporaryDirectory() as directory:
            helper = Path(directory) / "helper"
            helper.write_bytes(b"executable")
            Path(str(helper) + ".ll").write_text('target triple = "aarch64-apple-macosx15.0.0"\n')
            Path(str(helper) + ".development.ll").write_text("development IR\n")
            dependency = {"src/native-kernel.cr": "a" * 64, "docs/ignored.md": "b" * 64}
            proof = {"source": "c" * 64, "dependency_sources": {"src/native-kernel.cr": "a" * 64},
                     "compiler": "Crystal 1.22.2 [abc]\nDefault target: aarch64-apple-darwin\n",
                     "target": "aarch64-darwin", "native_symbols": [], "assembly": ["trap"],
                     "ir": module.sha256_file(Path(str(helper) + ".ll")),
                     "development_ir": module.sha256_file(Path(str(helper) + ".development.ll"))}
            Path(str(helper) + ".audit.json").write_text(json.dumps(proof))
            validate(helper, dependency, proof["compiler"], "arm64")
            Path(str(helper) + ".development.ll").write_text("tampered")
            with self.assertRaises(ValueError):
                validate(helper, dependency, proof["compiler"], "arm64")
            proof["development_ir"] = module.sha256_file(Path(str(helper) + ".development.ll"))
            proof["dependency_sources"]["src/native-kernel.cr"] = "d" * 64
            Path(str(helper) + ".audit.json").write_text(json.dumps(proof))
            with self.assertRaises(ValueError):
                validate(helper, dependency, proof["compiler"], "arm64")

    def test_incomplete_setup_exports_nonpassing_receipt(self):
        self.module()
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "evidence"
            result = subprocess.run([sys.executable, "-B", str(SCRIPT), "record-failure",
                                     "--profile", "macos-26-arm64", "--output", str(output),
                                     "--reason", "setup did not finish"], capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            receipt = json.loads((output / "export/receipt.json").read_text())
            self.assertNotEqual(receipt["status"], "passed")
            self.assertEqual(receipt["error"], "setup did not finish")

    def test_output_inside_either_checkout_is_refused_without_writes(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "process-control"
            dependency = Path(directory) / "native-kernel"
            root.mkdir()
            dependency.mkdir()
            for checkout in (root, dependency):
                for mode in ("qualify", "setup", "record-failure"):
                    output = checkout / ("forbidden-" + mode)
                    arguments = [mode, "--profile", "macos-15-arm64", "--output", str(output)]
                    if mode == "qualify":
                        arguments += ["--compiler", "crystal", "--compiler-version", "1.22.2"]
                    elif mode == "setup":
                        arguments.insert(1, "verify")
                        arguments += ["--compiler-version", "1.22.2"]
                    else:
                        arguments += ["--reason", "interrupted"]
                    with patch.object(module, "ROOT", root):
                        self.assertNotEqual(module.main(arguments), 0)
                    self.assertFalse(output.exists(), str(output))
            self.assertEqual(list(root.iterdir()), [])
            self.assertEqual(list(dependency.iterdir()), [])

    def test_export_excludes_compiler_cache_objects_and_spec_executable(self):
        export = self.function("export_evidence")
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / "logs").mkdir()
            (output / "logs/build.stdout").write_text("bounded log")
            (output / "compiler-cache").mkdir()
            (output / "compiler-cache/private").write_text("cache")
            (output / "helper").write_bytes(b"helper executable")
            (output / "helper.o").write_bytes(b"object")
            (output / "helper.ll").write_text("release IR")
            (output / "helper.development.ll").write_text("development IR")
            (output / "spec-runner").write_bytes(b"managed executable")
            (output / "spec-runner.cr").write_text("generated spec source")
            receipt = {"status": "failed"}
            export(output, receipt)
            self.assertEqual(set(receipt["bundle_files"]), {
                "logs/build.stdout", "helper/helper", "ir/helper.ll.gz", "ir/helper.development.ll.gz"})

    def test_passed_export_refuses_a_helper_changed_after_execution(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            helper = output / "helper"
            helper.write_bytes(b"audited helper")
            receipt = {"status": "passed", "helper_sha256": module.sha256_file(helper)}
            helper.write_bytes(b"changed helper")
            with self.assertRaisesRegex(ValueError, "helper changed"):
                module.export_evidence(output, receipt)

    def test_setup_failure_is_preserved_without_qualification(self):
        self.module()
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "evidence"
            result = subprocess.run([sys.executable, "-B", str(SCRIPT), "setup", "verify",
                                     "--profile", "invalid-profile", "--compiler-version", "1.22.2",
                                     "--output", str(output)], capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            receipt = json.loads((output / "export/receipt.json").read_text())
            self.assertEqual(receipt["status"], "failed")
            self.assertNotIn("completed_examples", receipt)


if __name__ == "__main__":
    unittest.main()
