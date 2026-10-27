#!/usr/bin/env python3
"""Build and check all offscreen UI states without opening an application window.

From a source checkout: python3 scripts/verify-ui.py
Requires macOS, Python 3.9+ and the Swift/Xcode tools already used to build the app.
No pip packages, Accessibility permission, microphone access, or transcription.
Every run owns a new temporary library; screenshots/logs/reports are retained.
"""

import argparse
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile


SCENARIOS = (
    ("recording-workspace", ("--workspace-preview",), True, (2560, 1640)),
    ("recording-workspace-minimum", ("--workspace-preview", "--minimum-window"), True, (2000, 1340)),
    ("recording-workspace-empty", ("--workspace-preview", "--notes-empty-preview"), True, (2560, 1640)),
    ("recording-workspace-collapsed", ("--workspace-preview", "--recorder-collapsed-preview"), True, (2560, 1640)),
    ("recording-workspace-paused", ("--workspace-preview", "--recorder-paused-preview", "--minimum-window"), True, (2000, 1340)),
    ("saved-notes", ("--saved-notes-preview",), True, (2560, 1640)),
    ("saved-notes-minimum", ("--saved-notes-preview", "--minimum-window"), True, (2000, 1340)),
    ("live-notes-editing", ("--workspace-preview", "--live-edit-preview"), True, (2560, 1640)),
    ("saved-notes-editing", ("--saved-notes-preview", "--live-edit-preview"), True, (2560, 1640)),
    ("notes-composing", ("--saved-notes-preview", "--notes-composing-preview"), True, (2560, 1640)),
    ("sidebar-library-search", ("--saved-notes-preview", "--library-search-preview", "--minimum-window"), True, (2000, 1340)),
    ("sidebar-favorites", ("--saved-notes-preview", "--favorites-preview", "--minimum-window"), True, (2000, 1340)),
    ("sidebar-folder", ("--saved-notes-preview", "--folder-library-preview", "--minimum-window"), True, (2000, 1340)),
    ("sidebar-ai-ready", ("--sidebar-ai-preview",), True, (2560, 1640)),
    ("sidebar-ai-checking", ("--sidebar-ai-preview", "--sidebar-ai-checking-preview", "--minimum-window"), True, (2000, 1340)),
    ("sidebar-ai-login", ("--sidebar-ai-preview", "--providers-login-preview", "--minimum-window"), True, (2000, 1340)),
    ("sidebar-ai-quota", ("--sidebar-ai-preview", "--sidebar-ai-quota-preview"), True, (2560, 1640)),
    ("sidebar-ai-unknown", ("--sidebar-ai-preview", "--sidebar-ai-unknown-preview", "--minimum-window"), True, (2000, 1340)),
    ("sidebar-ai-disabled", ("--sidebar-ai-preview", "--providers-disabled-preview", "--recording-only-preview", "--recording-active-preview", "--minimum-window"), True, (2000, 1340)),
    ("connection-unknown", ("--connection-preview",), False, (960, 700)),
    ("connection-login", ("--connection-preview", "--connection-login-preview"), False, (960, 700)),
    ("connection-install", ("--connection-preview", "--connection-install-preview"), False, (960, 820)),
    ("connection-quota", ("--connection-preview", "--connection-quota-preview"), False, (960, 700)),
    ("preview", (), True, (2560, 1640)),
    ("minimum", ("--minimum-window",), True, (2000, 1340)),
    ("notes", ("--notes-preview",), True, (2560, 1640)),
    ("focus", ("--focus-preview",), True, (2560, 1640)),
    ("settings", ("--settings-preview",), True, (1640, 1400)),
    ("providers", ("--providers-preview",), True, (1640, 1400)),
    ("providers-details", ("--providers-preview", "--provider-details-preview"), True, (1640, 1400)),
    ("settings-minimum", ("--settings-preview", "--minimum-window"), True, (1520, 1200)),
    ("providers-minimum", ("--providers-preview", "--minimum-window"), True, (1520, 1200)),
    ("providers-login", ("--providers-preview", "--providers-login-preview"), True, (1640, 1400)),
    ("providers-error", ("--providers-preview", "--providers-error-preview", "--minimum-window"), True, (1520, 1200)),
    ("providers-missing", ("--providers-preview", "--providers-missing-preview"), True, (1640, 1400)),
    ("providers-disabled", ("--providers-preview", "--providers-disabled-preview"), True, (1640, 1400)),
    ("settings-download", ("--settings-preview", "--speech-download-preview"), True, (1640, 1400)),
    ("settings-unavailable", ("--settings-preview", "--speech-unavailable-preview"), True, (1640, 1400)),
    ("shortcuts", ("--settings-preview", "--shortcuts-preview"), True, (1640, 1400)),
    ("highlights", ("--highlights-preview",), True, (2560, 1640)),
    ("highlights-minimum", ("--highlights-preview", "--minimum-window"), True, (2000, 1340)),
    ("highlights-long", ("--highlights-preview", "--summary-long-preview", "--minimum-window"), True, (2000, 1340)),
    ("highlights-empty", ("--highlights-preview", "--summary-empty-preview"), True, (2560, 1640)),
    ("evidence", ("--evidence-preview",), True, (2560, 1640)),
    ("evidence-minimum", ("--evidence-preview", "--minimum-window"), True, (2000, 1340)),
    ("welcome", (), False, (2560, 1640)),
    ("recording-only", ("--recording-only-preview",), True, (2560, 1640)),
    ("recording-only-minimum", ("--recording-only-preview", "--minimum-window"), True, (2000, 1340)),
    ("recording-only-active", ("--recording-only-preview", "--recording-active-preview", "--minimum-window"), True, (2000, 1340)),
    ("recording-help", ("--recording-help-preview",), False, (660, 700)),
    ("transcript", ("--transcript-preview",), True, (2560, 1640)),
    ("follow-return", ("--transcript-preview", "--follow-return-preview"), True, (2560, 1640)),
    ("follow-above", ("--transcript-preview", "--follow-return-preview", "--follow-above-preview", "--minimum-window"), True, (2000, 1340)),
    ("search", ("--transcript-preview", "--search-preview"), True, (2560, 1640)),
    ("empty-search", ("--minimum-window", "--transcript-preview", "--empty-search-preview"), True, (2000, 1340)),
    ("processing", ("--processing-preview",), True, (2560, 1640)),
    ("polishing", ("--polishing-preview",), True, (2560, 1640)),
    ("polishing-transcript", ("--polishing-preview", "--transcript-preview"), True, (2560, 1640)),
    ("polishing-minimum", ("--polishing-preview", "--minimum-window"), True, (2000, 1340)),
    ("polishing-overrun", ("--polishing-preview", "--overrun-preview", "--minimum-window"), True, (2000, 1340)),
    ("speech-download", ("--processing-preview", "--download-preview"), True, (2560, 1640)),
    ("summary", ("--summary-preview", "--transcript-preview"), True, (2560, 1640)),
    ("summary-only", ("--summary-preview", "--summary-only-preview", "--transcript-preview", "--minimum-window"), True, (2000, 1340)),
    ("queued", ("--queued-preview", "--minimum-window"), True, (2000, 1340)),
    ("interrupted", ("--minimum-window", "--transcript-preview", "--interrupted-preview"), True, (2000, 1340)),
    ("sleep", ("--minimum-window", "--sleep-preview"), True, (2000, 1340)),
    ("review", ("--minimum-window", "--transcript-preview", "--review-preview"), True, (2000, 1340)),
)


def png_size(path):
    """Read PNG's mandatory first IHDR chunk using only the standard library."""
    with path.open("rb") as image:
        header = image.read(24)
    if (len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n"
            or header[8:12] != struct.pack(">I", 13) or header[12:16] != b"IHDR"):
        raise ValueError("Missing or invalid PNG IHDR: {}".format(path))
    width, height = struct.unpack(">II", header[16:24])
    if width == 0 or height == 0:
        raise ValueError("PNG has an empty canvas: {}".format(path))
    return width, height


def run_logged(command, log, cwd):
    with log.open("wb") as stream:
        result = subprocess.run(command, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError("Command failed ({}); see {}".format(result.returncode, log))


def run_monitor(command, log, cwd):
    with log.open("wb") as stream:
        process = subprocess.Popen(command, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            return process.wait(timeout=40)
        except (KeyboardInterrupt, subprocess.TimeoutExpired):
            # The Swift helper handles SIGTERM and terminates only its own snapshot child.
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output", type=Path, help="New, nonexistent result directory (default: a fresh temporary directory)")
    parser.add_argument("--skip-build", action="store_true", help="Use the already packaged dist/둥둥이.app")
    parser.add_argument("--scenario", action="append", choices=[s[0] for s in SCENARIOS], help="Only check these states (repeatable)")
    options = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This check requires macOS and AppKit")
    root = Path(__file__).resolve().parent.parent
    if options.output:
        run_directory = options.output.expanduser().resolve()
        # Never reuse a caller's directory or point the app at an existing library.
        try:
            run_directory.mkdir(parents=True, exist_ok=False)
        except OSError as error:
            parser.error("--output must be a new writable directory: {}".format(error))
    else:
        run_directory = Path(tempfile.mkdtemp(prefix="bungbungi-ui-"))
    artifacts = run_directory / "artifacts"
    artifacts.mkdir()
    libraries = run_directory / "libraries"
    libraries.mkdir()
    executable = root / "dist" / "둥둥이.app" / "Contents" / "MacOS" / "BungBungi"
    helper = run_directory / "offscreen-check"
    results = []
    report = {"passed": False, "artifacts": str(artifacts), "libraries": str(libraries), "checks": results}
    report_path = artifacts / "offscreen-validation.json"
    print("결과 저장 위치: {}".format(run_directory), flush=True)
    try:
        if not options.skip_build:
            print("앱 빌드 중…", flush=True)
            run_logged(["/bin/bash", str(root / "scripts" / "build-app.sh"), "debug"], artifacts / "build.log", root)
        if not executable.is_file():
            raise RuntimeError("Packaged executable not found: {}".format(executable))
        run_logged(["xcrun", "swiftc", "-swift-version", "5", str(root / "scripts" / "offscreen-check.swift"), "-o", str(helper)],
                   artifacts / "helper-build.log", root)
        for name, extra, demo, expected_size in SCENARIOS:
            if options.scenario and name not in options.scenario:
                continue
            screenshot = artifacts / (name + ".png")
            monitor_report = artifacts / (name + ".json")
            app_log = artifacts / (name + ".app.log")
            command = [str(helper), str(executable), str(app_log), str(monitor_report),
                       "--library", str(libraries / name), "--snapshot", str(screenshot)]
            if demo:
                command.append("--demo")
            command.extend(extra)
            code = run_monitor(command, artifacts / (name + ".monitor.log"), root)
            if not monitor_report.is_file():
                raise RuntimeError("{}: monitor report missing; see {}".format(name, artifacts / (name + ".monitor.log")))
            state = json.loads(monitor_report.read_text(encoding="utf-8"))
            state.update({"view": name, "screenshot": str(screenshot), "monitorExit": code})
            results.append(state)
            if code != 0 or not state.get("passed"):
                raise RuntimeError("{}: {}".format(name, "; ".join(state.get("failures", ["monitor failed"]))))
            # Recheck monitor fields explicitly. Invisible internal SwiftUI windows are allowed.
            if (state.get("visibleWindows") != 0 or state.get("active") is not False
                    or state.get("activationPolicy") != 2 or state.get("exit") != 0
                    or state.get("activationEventObserved") is not False
                    or state.get("frontmostObserved") is not False):
                raise RuntimeError("{}: background activation invariant failed".format(name))
            size = png_size(screenshot)
            state["pixels"] = list(size)
            if size != expected_size:
                state["passed"] = False
                raise RuntimeError("{}: PNG size {} differs from expected {}".format(name, size, expected_size))
            print("PASS {}: {}×{}, visible=0, active=false, policy=2".format(name, *size), flush=True)
        report["passed"] = True
    except KeyboardInterrupt:
        report["error"] = "Interrupted; the monitor was asked to stop its snapshot child"
    except Exception as error:
        report["error"] = str(error)
    finally:
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("검증 보고서: {}".format(report_path), flush=True)
    if not report["passed"]:
        print("FAIL: {}".format(report.get("error", "Unknown failure")), file=sys.stderr)
        return 1
    print("전체 {}개 화면 통과. 기존 사용자 라이브러리는 사용하지 않았습니다.".format(len(results)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
