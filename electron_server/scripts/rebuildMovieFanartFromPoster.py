#!/usr/bin/env python3
"""Rebuild movie fanart from the right half of its indexed post/poster image.

Runs on the NasCabOS Docker host. Python's standard library plus ffmpeg/ffprobe
are sufficient; no scrape or network request is made. A dry run is the default.

Example:
  python3 rebuildMovieFanartFromPoster.py
  python3 rebuildMovieFanartFromPoster.py --apply
  python3 rebuildMovieFanartFromPoster.py --apply --id 29707
"""

import argparse
import html
import json
import os
import re
import sqlite3
import stat
import subprocess
import sys
import tempfile
from collections import Counter, defaultdict
from pathlib import Path
from xml.etree import ElementTree


DEFAULT_DB = "/home/ermao/appdata/nascab/nascabosdata/database/nascab_video.db"
DEFAULT_MOUNTS = (
    "/myMedia=/home/ermao/appdata/nascab/mymedia",
    "/ptStorage=/home/ermao/appdata/nascab/ptstorage",
    "/ssdMedia=/home/ermao/appdata/nascab/media-ssd",
)
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp"}
PART_SUFFIX = re.compile(r"(?:[._ -]CD\d+)$", re.IGNORECASE)
FANART_BLOCK = re.compile(r"<fanart\b[^>]*>[\s\S]*?</fanart>", re.IGNORECASE)
FANART_THUMB = re.compile(r"<thumb\b[^>]*>[\s\S]*?</thumb>", re.IGNORECASE)


def parse_mounts(values):
    mounts = []
    for value in values:
        container, separator, host = value.partition("=")
        if not separator or not container.startswith("/") or not host.startswith("/"):
            raise ValueError(f"Invalid --mount: {value}")
        mounts.append((Path(container), Path(host)))
    return sorted(mounts, key=lambda pair: len(str(pair[0])), reverse=True)


def to_host_path(container_path, mounts):
    candidate = Path(container_path)
    for container, host in mounts:
        try:
            relative = candidate.relative_to(container)
        except ValueError:
            continue
        return host / relative
    raise ValueError(f"No mount for {container_path}")


def safe_artwork_path(directory, relative):
    if not relative or Path(relative).is_absolute():
        return None
    target = (directory / relative).resolve()
    if not target.is_relative_to(directory.resolve()):
        return None
    return target


def image_size(image):
    try:
        result = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
             "stream=width,height", "-of", "json", str(image)],
            capture_output=True, text=True, check=True,
        )
    except FileNotFoundError:
        result = subprocess.run(["ffmpeg", "-hide_banner", "-i", str(image)], capture_output=True, text=True)
        video_line = next((line for line in result.stderr.splitlines() if "Video:" in line), "")
        match = re.search(r"(?<!\d)(\d{2,5})x(\d{2,5})(?!\d)", video_line)
        if not match:
            raise ValueError(f"Image cannot be decoded: {image}")
        return int(match.group(1)), int(match.group(2))
    streams = json.loads(result.stdout).get("streams") or []
    if not streams:
        raise ValueError(f"Image cannot be decoded: {image}")
    return int(streams[0]["width"]), int(streams[0]["height"])


def fanart_name(poster_relative, current_relative):
    poster = Path(poster_relative)
    current = Path(current_relative) if current_relative else None
    if current and current != poster and current.suffix.lower() in {".jpg", ".jpeg"}:
        return str(current)
    stem = poster.stem
    if re.search(r"-(?:post|poster)$", stem, re.IGNORECASE):
        stem = re.sub(r"-(?:post|poster)$", "-fanart", stem, flags=re.IGNORECASE)
    elif stem.lower() in {"poster", "folder", "cover"}:
        stem = "fanart"
    else:
        stem += "-fanart"
    name = f"{stem}.jpg"
    if len(name.encode("utf-8")) > 240:
        name = "fanart.jpg"
    return str(poster.with_name(name))


def find_nfo(directory, filename):
    stem = Path(filename).stem
    candidates = [f"{stem}.nfo"]
    shared = PART_SUFFIX.sub("", stem)
    if shared != stem:
        candidates.append(f"{shared}.nfo")
    candidates += ["movie.nfo", f"{directory.name}.nfo"]
    for candidate in candidates:
        file = directory / candidate
        if file.is_file():
            return file
    return None


def replace_nfo_fanart(xml, fanart_relative):
    escaped = html.escape(fanart_relative, quote=False)
    thumb = f"<thumb>{escaped}</thumb>"
    if FANART_BLOCK.search(xml):
        def replace_block(match):
            block = match.group(0)
            if FANART_THUMB.search(block):
                return FANART_THUMB.sub(thumb, block, count=1)
            return block.replace("</fanart>", f"{thumb}</fanart>")
        return FANART_BLOCK.sub(replace_block, xml, count=1)
    if not re.search(r"</movie>", xml, re.IGNORECASE):
        raise ValueError("NFO has no closing </movie> tag")
    return re.sub(r"</movie>", f"  <fanart>{thumb}</fanart>\n</movie>", xml, count=1, flags=re.IGNORECASE)


def crop_right_half(source, target, width, height):
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(prefix=".fanart-", suffix=".jpg", dir=target.parent, delete=False) as handle:
        temporary = Path(handle.name)
    try:
        crop_x = width // 2
        command = [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-i", str(source), "-vf", f"crop={width - crop_x}:{height}:{crop_x}:0:exact=1",
            "-frames:v", "1", "-q:v", "2", str(temporary),
        ]
        subprocess.run(command, capture_output=True, text=True, check=True)
        if temporary.stat().st_size < 1000:
            raise ValueError(f"Generated fanart is too small: {target}")
        out_width, out_height = image_size(temporary)
        if abs(out_width - (width - crop_x)) > 1 or out_height != height:
            raise ValueError(f"Unexpected crop dimensions: {target}")
        original_stat = target.stat() if target.exists() else source.stat()
        mode = stat.S_IMODE(original_stat.st_mode)
        os.chmod(temporary, mode)
        try:
            os.chown(temporary, original_stat.st_uid, original_stat.st_gid)
        except PermissionError:
            pass
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default=DEFAULT_DB)
    parser.add_argument("--mount", action="append", help="Container mount mapping, e.g. /myMedia=/path/on/host")
    parser.add_argument("--id", type=int, action="append", help="Process only this video_index id; repeatable")
    parser.add_argument("--apply", action="store_true", help="Write fanart, NFO and database changes")
    parser.add_argument("--skip-current", action="store_true", help="Skip already indexed fanart with the expected crop dimensions")
    parser.add_argument("--min-ratio", type=float, default=1.25, help="Minimum post width/height ratio (default: 1.25)")
    args = parser.parse_args()
    mounts = parse_mounts(args.mount or DEFAULT_MOUNTS)
    db_location = args.db if args.apply else f"file:{Path(args.db).absolute()}?mode=ro"
    db = sqlite3.connect(db_location, timeout=30, uri=not args.apply)
    db.row_factory = sqlite3.Row
    query = "SELECT id,path,filename,poster_path,fanart_path FROM video_index WHERE media_type IN ('movie','bdmv','video_ts') AND poster_path <> ''"
    values = []
    if args.id:
        query += f" AND id IN ({','.join('?' for _ in args.id)})"
        values = args.id
    rows = db.execute(query, values).fetchall()
    by_image = defaultdict(list)
    skipped = Counter()
    for row in rows:
        try:
            directory = to_host_path(row["path"], mounts)
            source = safe_artwork_path(directory, row["poster_path"])
            if not source or not source.is_file() or source.stat().st_size == 0:
                skipped["missing_post"] += 1
                continue
            if source.suffix.lower() not in IMAGE_SUFFIXES:
                skipped["unsupported_post"] += 1
                continue
            by_image[source].append((row, directory))
        except (OSError, ValueError):
            skipped["invalid_path"] += 1
    processed = 0
    affected_rows = 0
    nfo_changed = 0
    examples = []
    reserved_targets = {}
    for source, group in by_image.items():
        try:
            width, height = image_size(source)
            if height <= 0 or width / height < args.min_ratio:
                skipped["portrait_or_square"] += len(group)
                continue
            relative = fanart_name(group[0][0]["poster_path"], group[0][0]["fanart_path"])
            target = safe_artwork_path(group[0][1], relative)
            if not target or target == source:
                skipped["invalid_fanart_path"] += len(group)
                continue
            if any(safe_artwork_path(directory, relative) != target for _, directory in group):
                skipped["shared_image_across_directories"] += len(group)
                continue
            if target in reserved_targets and reserved_targets[target] != source:
                skipped["fanart_target_collision"] += len(group)
                continue
            reserved_targets[target] = source
            nfos = {}
            for row, directory in group:
                nfo = find_nfo(directory, row["filename"])
                if nfo:
                    original = nfo.read_text(encoding="utf-8")
                    changed = replace_nfo_fanart(original, relative)
                    ElementTree.fromstring(changed)
                    if nfo in nfos and nfos[nfo][1] != changed:
                        raise ValueError(f"Conflicting NFO update: {nfo}")
                    nfos[nfo] = (original, changed)
            if args.skip_current and target.is_file() and target.stat().st_size > 0:
                expected_width = width - width // 2
                if (image_size(target) == (expected_width, height)
                        and all(row["fanart_path"] == relative for row, _ in group)
                        and all(original == changed for original, changed in nfos.values())):
                    skipped["already_current"] += len(group)
                    continue
            if len(examples) < 12:
                examples.append({"ids": [r["id"] for r, _ in group], "post": str(source), "fanart": str(target), "size": [width, height]})
            if args.apply:
                crop_right_half(source, target, width, height)
                for nfo, (original, changed) in nfos.items():
                    if original != changed:
                        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", prefix=".nfo-", suffix=".tmp", dir=nfo.parent, delete=False) as handle:
                            handle.write(changed)
                            temporary_nfo = Path(handle.name)
                        nfo_stat = nfo.stat()
                        os.chmod(temporary_nfo, stat.S_IMODE(nfo_stat.st_mode))
                        try:
                            os.chown(temporary_nfo, nfo_stat.st_uid, nfo_stat.st_gid)
                        except PermissionError:
                            pass
                        os.replace(temporary_nfo, nfo)
                        nfo_changed += 1
                with db:
                    db.executemany("UPDATE video_index SET fanart_path=? WHERE id=?", [(relative, row["id"]) for row, _ in group])
            processed += 1
            affected_rows += len(group)
            if args.apply and processed % 100 == 0:
                print(f"Processed {processed} images, updated {affected_rows} index rows", flush=True)
        except (OSError, ValueError, ElementTree.ParseError, subprocess.CalledProcessError, sqlite3.Error) as error:
            skipped["failed"] += len(group)
            if len(examples) < 12:
                examples.append({"post": str(source), "error": str(error)})
    print(json.dumps({"mode": "apply" if args.apply else "dry-run", "images": processed,
                      "index_rows": affected_rows, "nfo_files_updated": nfo_changed,
                      "skipped": dict(skipped), "examples": examples}, ensure_ascii=False, indent=2))
    db.close()
    if args.apply and skipped["failed"]:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
