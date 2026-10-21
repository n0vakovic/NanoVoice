#!/usr/bin/env python3
"""Run focused production-code checks without Bazel or persistent build caches."""
from pathlib import Path
import subprocess
import tempfile
import re

root = Path(__file__).resolve().parents[2]
sources = root / "submodules/TelegramUI/Sources"

# Regression: a one-entry preview request compiles but crashes Postbox at runtime.
# Check actual call sites, not a separate test-only copy of the request parameter.
home = (sources / "NanoVoiceHomeController.swift").read_text()
preview_counts = re.findall(r"aroundMessageHistoryViewForLocation\([^\n]*?count: (\d+)", home)
assert preview_counts and all(int(count) >= 2 for count in preview_counts), "Postbox history previews require count >= 2"


def run(*args):
    subprocess.run(args, cwd=root, check=True)

with tempfile.TemporaryDirectory(prefix="nanovoice-checks-") as temp:
    scratch = Path(temp)
    for name, source, test in [
        ("audio-diagnostics", "../../TelegramAudio/Sources/NanoVoiceAudioDiagnostics.swift", "Tests/NanoVoiceAudioDiagnostics/main.swift"),
        ("agents", "NanoVoiceAgentStore.swift", "Tests/NanoVoiceAgents/main.swift"),
        ("delivery", "WalkReplyGate.swift", "Tests/WalkLive/main.swift"),
        ("drafts", "WalkDraftStore.swift", "Tests/WalkDrafts/main.swift"),
        ("diagnostics", "WalkDiagnostics.swift", "Tests/WalkDiagnostics/main.swift"),
    ]:
        executable = scratch / name
        run("swiftc", "-warnings-as-errors", "-module-cache-path", str(scratch / "cache"),
            str(sources / source), test, "-o", str(executable))
        run(str(executable))
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
    run("swiftc", "-typecheck", "-warnings-as-errors", "-sdk", sdk,
        "-target", "arm64-apple-ios13.0", "-module-cache-path", str(scratch / "ios-cache"),
        *(str(sources / name) for name in ["WalkReplyGate.swift", "WalkDraftStore.swift", "WalkDiagnostics.swift"]))
    run("swiftc", "-frontend", "-parse", *(str(sources / name) for name in [
        "WalkVoiceSession.swift", "WalkAudioDiagnosticsMonitor.swift", "WalkChatControls.swift", "NanoVoiceHomeController.swift", "ChatController.swift"
    ]))
run("python3", "Tests/WalkLive/test_capture.py")
run("git", "diff", "--check")
print("PASS: focused Walk checks (not a complete app build or device test)")
