#!/usr/bin/env python3
"""下载固定提交的兼容版播放器 AAR，并逐个验证 SHA-256。"""
import hashlib
import json
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = json.loads(Path(__file__).with_name("manifest.json").read_text())
TARGET = ROOT / "app" / "libs"
TARGET.mkdir(parents=True, exist_ok=True)
for entry in MANIFEST["files"]:
    name = entry["file"]
    if Path(name).name != name or not name.startswith("lib-") or not name.endswith(".aar"):
        raise ValueError("依赖清单包含非法文件名")
    target = TARGET / name
    if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() == entry["sha256"]:
        print("已校验：", name)
        continue
    url = f'https://raw.githubusercontent.com/{MANIFEST["repository"]}/{MANIFEST["commit"]}/TV-fongmi/app/libs/{name}'
    data = urllib.request.urlopen(url, timeout=120).read()
    if len(data) != entry["bytes"] or hashlib.sha256(data).hexdigest() != entry["sha256"]:
        raise ValueError("依赖校验失败：" + name)
    temporary = target.with_suffix(".download")
    temporary.write_bytes(data)
    temporary.replace(target)
    print("已下载并校验：", name)
