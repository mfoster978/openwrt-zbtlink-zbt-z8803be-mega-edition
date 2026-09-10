#!/usr/bin/env python3
"""Generate evidence-bound OpenWrt release notes with Gemini."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

SYSTEM = """You write detailed, professional firmware release notes for ZBT-Z8803BE router users.
Use only the supplied repository evidence. Never invent hardware support, test results, fixes, or compatibility.
Return Markdown with exactly these headings, in this order: ## Highlights, ## Bug fixes, ## Features and additions, ## Upgrade notes.
Under every heading write one or more specific bullet points. Explain user-visible behavior and useful technical details.
Call out anything users should verify after flashing. Do not mention CI implementation, prompts, API keys, commit hashes, or source-code housekeeping.
Keep the complete response between 700 and 2200 characters. Do not add a title or preamble."""


def request(key: str, model: str, prompt: str) -> str:
    endpoint = "https://generativelanguage.googleapis.com/v1beta/models/" + urllib.parse.quote(model, safe="-._") + ":generateContent"
    body = json.dumps({
        "system_instruction": {"parts": [{"text": SYSTEM}]},
        "contents": [{"role": "user", "parts": [{"text": prompt}]}],
        "generationConfig": {"temperature": 0.2, "maxOutputTokens": 4096},
    }).encode()
    last = "Gemini request failed"
    for delay in (0, 2, 5, 10):
        if delay:
            time.sleep(delay)
        req = urllib.request.Request(endpoint, data=body, method="POST", headers={"Content-Type": "application/json", "x-goog-api-key": key})
        try:
            with urllib.request.urlopen(req, timeout=90) as response:
                payload = json.loads(response.read().decode())
            parts = payload.get("candidates", [{}])[0].get("content", {}).get("parts", [])
            text = "".join(p.get("text", "") for p in parts if not p.get("thought", False)).strip()
            if text:
                return text
            last = "Gemini returned no release-note text"
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            try:
                last = json.loads(raw).get("error", {}).get("message", last)
            except json.JSONDecodeError:
                last = f"Gemini returned HTTP {exc.code}"
            if exc.code not in {408, 429, 500, 502, 503, 504}:
                break
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            last = f"Gemini request failed: {exc}"
    raise RuntimeError(last)


def valid(text: str) -> bool:
    clean = text.replace("\r", "").strip()
    headings = re.findall(r"^## .+$", clean, re.MULTILINE)
    expected = ["## Highlights", "## Bug fixes", "## Features and additions", "## Upgrade notes"]
    bullets = re.findall(r"^- .+", clean, re.MULTILINE)
    return headings == expected and len(bullets) >= 4 and 700 <= len(clean) <= 2200 and "```" not in clean


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", required=True)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    key = os.environ.get("GEMINI_API_KEY", "").strip()
    model = os.environ.get("GEMINI_MODEL", "gemini-flash-latest").strip()
    if not key:
        print("GEMINI_API_KEY is not configured", file=sys.stderr)
        return 1
    if not args.evidence.is_file() or not args.evidence.stat().st_size:
        print("Release evidence is missing", file=sys.stderr)
        return 1
    prompt = f"Firmware: {args.name}\n\nChanges since the previous published firmware:\n{args.evidence.read_text(errors='replace')}"
    try:
        text = request(key, model, prompt)
        if not valid(text):
            text = request(key, model, prompt + "\n\nYour last answer failed the exact heading, bullet, or length rules. Rewrite it correctly and keep every claim tied to the evidence.")
        if not valid(text):
            raise RuntimeError("Gemini did not return valid detailed release notes after one correction")
    except RuntimeError as exc:
        print(exc, file=sys.stderr)
        return 1
    args.output.write_text(text.strip() + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
