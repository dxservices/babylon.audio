#!/usr/bin/env python3

from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
IGNORED_PARTS = {".build", ".git", ".swiftpm"}
CJK = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]")
TEXT_SUFFIXES = {".md", ".py", ".swift", ".yml", ".yaml"}
TEXT_NAMES = {"Package.swift", "AGENTS.md", "LICENSE", ".gitignore"}
FORBIDDEN_SOURCE_TERMS = {
    "OpenAI",
    "Google",
    "Zoom",
    "Keychain",
    "UserDefaults",
    "SwiftUI",
    "URLSessionWebSocket",
    "Logger",
}
CONTENT_BEARING_TERMS = re.compile(r"\b(?:Codable|Data|Error|String)\b")


def repository_text_files():
    for path in ROOT.rglob("*"):
        if not path.is_file() or any(part in IGNORED_PARTS for part in path.parts):
            continue
        if path.suffix in TEXT_SUFFIXES or path.name in TEXT_NAMES or path.suffix == "":
            try:
                path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            yield path


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


for file_path in repository_text_files():
    text = file_path.read_text(encoding="utf-8")
    if CJK.search(text):
        fail(f"Non-English CJK text found in {file_path.relative_to(ROOT)}")

source_root = ROOT / "Sources" / "BabylonAudio"
for file_path in source_root.rglob("*.swift"):
    text = file_path.read_text(encoding="utf-8")
    for term in FORBIDDEN_SOURCE_TERMS:
        if term in text:
            fail(f"Forbidden boundary term {term!r} found in {file_path.relative_to(ROOT)}")

observability_contract = source_root / "AudioObservability.swift"
if observability_contract.exists():
    text = observability_contract.read_text(encoding="utf-8")
    match = CONTENT_BEARING_TERMS.search(text)
    if match:
        fail(
            "Content-bearing term "
            f"{match.group(0)!r} found in {observability_contract.relative_to(ROOT)}"
        )

frame_contract = source_root / "AudioContracts.swift"
if frame_contract.exists() and re.search(
    r"\b(?:Codable|Encodable|Decodable)\b",
    frame_contract.read_text(encoding="utf-8"),
):
    fail("Persistence conformance found in the audio frame contract")

if (ROOT / ".git").exists():
    shallow_result = subprocess.run(
        ["git", "rev-parse", "--is-shallow-repository"],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if shallow_result.returncode != 0:
        fail("Unable to determine whether repository history is shallow")
    if shallow_result.stdout.strip() == "true":
        fail("Shallow history cannot prove English-only commit messages from the first commit")

    result = subprocess.run(
        ["git", "log", "--all", "--format=%B"],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        fail("Unable to inspect reachable commit messages")
    if CJK.search(result.stdout):
        fail("Non-English CJK text found in reachable commit messages")

print("Repository language and source-boundary checks passed.")
