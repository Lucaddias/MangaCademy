#!/usr/bin/env python3
"""
Gera Resources/keiyoushi_catalog.json a partir do repositório Keiyoushi.

As extensões do Keiyoushi são APKs Android (Kotlin) e não rodam no iOS. Este script
lê o índice oficial (https://github.com/keiyoushi/extensions/raw/repo/index.json) e
o código-fonte (https://github.com/keiyoushi/extensions-source) para descobrir qual
"tema" (motor) cada extensão usa — Madara, MangaThemesia, ZeistManga, Keyoapp, Iken,
MangaDex... — e quais ajustes cada site sobrescreve. O app usa esse mapa para rodar o
motor Swift equivalente com a URL de cada fonte.

Uso:
    python3 tools/build_keiyoushi_catalog.py                  # baixa tudo sozinho
    python3 tools/build_keiyoushi_catalog.py --source-dir DIR --index index.json
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request
from datetime import datetime, timezone

INDEX_URL = "https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.json"
SOURCE_REPO = "https://github.com/keiyoushi/extensions-source.git"
PKG_PREFIX = "eu.kanade.tachiyomi.extension."

# Temas com motor Swift implementado no app
SUPPORTED_THEMES = {"madara", "mangathemesia", "zeistmanga", "keyoapp", "iken"}
# Extensões próprias (sem tema) com motor Swift dedicado
CUSTOM_ENGINES = {
    "all.mangadex": "mangadex",
    "all.comicklive": "comick",
    "pt.spectralscan": "nexustoons",  # "Nexus Toons" (nexustoons.com)
}


def fetch_index(path):
    if path:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    req = urllib.request.Request(INDEX_URL, headers={"User-Agent": "MihonReader-catalog"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)


def checkout_sources(target):
    git = ["git", "-c", "core.hooksPath=/dev/null"]
    subprocess.run(git + ["clone", "--quiet", "--depth", "1", "--filter=blob:none", "--sparse",
                          "--no-checkout", SOURCE_REPO, target], check=True)
    subprocess.run(git + ["-C", target, "sparse-checkout", "set", "--no-cone",
                          "/src/*/*/build.gradle.kts", "/src/*/*/build.gradle", "/src/*/*/src/"], check=True)
    subprocess.run(git + ["-C", target, "checkout", "--quiet"], check=True)


def read_extension(source_dir, key):
    lang, name = key.split(".", 1)
    ext_dir = os.path.join(source_dir, "src", lang, name)
    gradle = ""
    for fname in ("build.gradle.kts", "build.gradle"):
        p = os.path.join(ext_dir, fname)
        if os.path.exists(p):
            with open(p, encoding="utf-8", errors="ignore") as f:
                gradle = f.read()
            break
    kotlin = []
    src = os.path.join(ext_dir, "src")
    for root, _, files in os.walk(src):
        for fname in files:
            if fname.endswith(".kt"):
                with open(os.path.join(root, fname), encoding="utf-8", errors="ignore") as f:
                    kotlin.append(f.read())
    return gradle, "\n".join(kotlin)


def str_override(code, prop):
    m = re.search(r"override\s+val\s+%s\s*(?::\s*\w+\??\s*)?=\s*\"([^\"]*)\"" % prop, code)
    return m.group(1) if m else None


def bool_override(code, prop):
    m = re.search(r"override\s+val\s+%s\s*(?::\s*\w+\s*)?=\s*(true|false)" % prop, code)
    return None if not m else m.group(1) == "true"


def int_override(code, prop):
    m = re.search(r"override\s+val\s+%s\s*(?::\s*\w+\s*)?=\s*(\d+)" % prop, code)
    return int(m.group(1)) if m else None


def engine_for(key, gradle, code):
    if key in CUSTOM_ENGINES:
        return {"type": CUSTOM_ENGINES[key]}
    m = re.search(r"\btheme\s*=\s*\"([^\"]+)\"", gradle) or re.search(r"themePkg\s*=\s*['\"]([^'\"]+)", gradle)
    theme = m.group(1) if m else None
    if theme not in SUPPORTED_THEMES:
        return None
    engine = {"type": theme}
    if theme == "madara":
        engine["noAjax"] = bool(re.search(r":\s*MadaraNoAjax\b", code))
        mode = re.search(r"override\s+val\s+chapterMode\s*=\s*ChapterMode\.(\w+)", code)
        if mode:
            engine["chapterMode"] = mode.group(1)
        for prop in ("mangaSubString", "ajaxTemplate"):
            v = str_override(code, prop)
            if v is not None:
                engine[prop] = v
        for prop in ("supportsPostId", "filterNonMangaItems"):
            v = bool_override(code, prop)
            if v is not None:
                engine[prop] = v
        v = int_override(code, "pageSize")
        if v:
            engine["pageSize"] = v
    elif theme == "mangathemesia":
        v = str_override(code, "mangaUrlDirectory")
        if v:
            engine["mangaUrlDirectory"] = v
    elif theme == "zeistmanga":
        for prop in ("mangaCategory", "chapterCategory"):
            v = str_override(code, prop)
            if v:
                engine[prop] = v
    elif theme == "keyoapp":
        if re.search(r":\s*KeyoappV2\b", code):
            return None  # API diferente, ainda não suportada
    elif theme == "iken":
        v = str_override(code, "apiUrl")
        if v:
            engine["apiUrl"] = v
        v = int_override(code, "perPage")
        if v:
            engine["perPage"] = v
    return engine


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source-dir", help="checkout existente de keiyoushi/extensions-source")
    ap.add_argument("--index", help="index.json já baixado")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "Resources", "keiyoushi_catalog.json"))
    args = ap.parse_args()

    index = fetch_index(args.index)
    extensions = index["extensionList"]["extensions"]

    tmp = None
    source_dir = args.source_dir
    if not source_dir:
        tmp = tempfile.mkdtemp(prefix="keiyoushi-src-")
        source_dir = os.path.join(tmp, "extensions-source")
        checkout_sources(source_dir)

    out_exts = []
    supported_sources = 0
    for ext in extensions:
        key = ext["packageName"].replace(PKG_PREFIX, "")
        gradle, code = read_extension(source_dir, key)
        engine = engine_for(key, gradle, code)
        sources = [{
            "id": s["id"],
            "name": s["name"],
            "lang": s["language"],
            "baseUrl": s["homeUrl"].rstrip("/"),
        } for s in ext.get("sources", [])]
        if engine:
            supported_sources += len(sources)
        out_exts.append({
            "name": ext["name"],
            "pkg": ext["packageName"],
            "version": ext.get("versionName", ""),
            "iconUrl": ext.get("resources", {}).get("iconUrl", ""),
            "contentWarning": ext.get("contentWarning", "").replace("CONTENT_WARNING_", ""),
            "engine": engine,
            "sources": sources,
        })

    catalog = {
        "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "extensions": out_exts,
    }
    out = os.path.abspath(args.out)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, separators=(",", ":"))
    total = sum(len(e["sources"]) for e in out_exts)
    print(f"{len(out_exts)} extensões, {total} fontes, {supported_sources} com motor iOS -> {out}")


if __name__ == "__main__":
    sys.exit(main())
