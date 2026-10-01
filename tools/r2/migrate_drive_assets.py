#!/usr/bin/env python3
"""Move the seeded catalogue art from Google Drive to Cloudflare R2.

The owner's pictures, table pictures, emojis, badges and level art were
hosted on Google Drive (V1.0.1__seed.sql, V1.0.2__seed-festive-capybara.sql),
and six levels' art was served by the game server itself from
go-server/public/levels/ (a path such as /levels/royal-titan.json). This
copies every one of them into the R2 bucket the server signs URLs for
(go-server/internal/assets), byte for byte, and writes the mapping the seed's
moves were written from (drive-to-r2.tsv beside this script). A source that is
a path is read from --public instead of downloaded.

Input: a manifest, one row per catalogue row that names a Drive URL, as the
server seeds them — exported from a schema migrated with the seed:

    table <TAB> id/level/sort <TAB> name/code <TAB> asset_format <TAB> url <TAB> url2/title

(url2 is a table picture's night file; a badge's sixth column is its title).

For each file it:
  * downloads it (Drive's direct-download form, redirects followed);
  * refuses anything that is a web page (Drive answers a file it will not
    hand out with a sign-in or quota page, status 200) — CLAUDE.md §8.4;
  * checks a LOTTIE row parses as a Lottie (JSON with "layers") and an IMAGE
    row is a PNG, JPEG, WebP or GIF, naming the extension from what it is;
  * uploads it under its key with its content type and a year's immutable
    Cache-Control (a key's bytes never change: a changed file gets a new key,
    as a changed picture needed a new URL before), skipping a key already in
    the bucket with the same size unless --force;
  * reads it back with HEAD and checks size and content type.

Credentials come from go-server/.env (R2_ACCOUNT_ID, R2_ACCESS_KEY_ID,
R2_SECRET_ACCESS_KEY, R2_BUCKET_NAME) and are handed to the AWS CLI through
its environment; nothing prints them.

    python3 tools/r2/migrate_drive_assets.py manifest.tsv \
        --env go-server/.env --out /tmp/r2-files --mapping tools/r2/drive-to-r2.tsv
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

CACHE_CONTROL = "public, max-age=31536000, immutable"

IMAGE_KINDS = (
    (b"\x89PNG\r\n\x1a\n", "png", "image/png"),
    (b"\xff\xd8\xff", "jpg", "image/jpeg"),
    (b"GIF8", "gif", "image/gif"),
)


def slug(text):
    text = text.lower().replace("'", "")
    return re.sub(r"[^a-z0-9]+", "-", text).strip("-")


def load_env(path):
    values = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip('"').strip("'")
    missing = [k for k in ("R2_ACCOUNT_ID", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "R2_BUCKET_NAME")
               if not values.get(k)]
    if missing:
        sys.exit("missing in %s: %s" % (path, ", ".join(missing)))
    return values


def fetch(url):
    """The file at url: (bytes, content type). Retries a few times: Drive
    sometimes answers a burst of downloads with a transient error."""
    last = None
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "king-teenpatti-asset-move/1"})
            with urllib.request.urlopen(req, timeout=60) as res:
                if res.status != 200:
                    raise RuntimeError("status %d" % res.status)
                return res.read(), (res.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        except Exception as e:  # noqa: BLE001 — reported after the retries
            last = e
            time.sleep(2 * (attempt + 1))
    raise RuntimeError("%s: %s" % (url, last))


def looks_like_html(data):
    head = data[:512].lstrip().lower()
    return head.startswith(b"<!doctype html") or head.startswith(b"<html")


def check(data, content_type, fmt, url):
    """The extension and content type to store data under, or an error."""
    if content_type == "text/html" or looks_like_html(data):
        raise RuntimeError("%s answered a web page, not the file" % url)
    if fmt == "LOTTIE":
        try:
            doc = json.loads(data)
        except ValueError as e:
            raise RuntimeError("%s is not JSON: %s" % (url, e))
        if not isinstance(doc, dict) or "layers" not in doc:
            raise RuntimeError("%s is JSON but not a Lottie" % url)
        return "json", "application/json"
    if fmt == "IMAGE":
        for magic, ext, ctype in IMAGE_KINDS:
            if data.startswith(magic):
                return ext, ctype
        if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
            return "webp", "image/webp"
        raise RuntimeError("%s is not a PNG, JPEG, WebP or GIF" % url)
    raise RuntimeError("%s: unexpected asset format %s" % (url, fmt))


def files_of(rows):
    """Every file to move: (table, label, fmt, url, key stem). A table
    picture whose night file is its day file is one file."""
    out = []
    seen_stems = set()
    for table, ident, name, fmt, url, extra in rows:
        if table == "profile_pictures":
            items = [(url, "profile_pictures/" + slug(name))]
        elif table == "emojis":
            items = [(url, "emojis/" + slug(name))]
        elif table == "badges":
            items = [(url, "badges/" + slug(name))]
        elif table == "player_levels":
            items = [(url, "levels/%02d-%s" % (int(ident), slug(extra or name)))]
        elif table == "table_pictures":
            if url == extra:
                items = [(url, "table_pictures/" + slug(name))]
            else:
                items = [(url, "table_pictures/%s-day" % slug(name)),
                         (extra, "table_pictures/%s-night" % slug(name))]
        else:
            raise SystemExit("unknown table " + table)
        for source, stem in items:
            if stem in seen_stems:
                raise SystemExit("two files would share the key " + stem)
            seen_stems.add(stem)
            out.append((table, name, fmt, source, stem))
    return out


def aws(env, *args):
    run_env = dict(os.environ)
    run_env.update({
        "AWS_ACCESS_KEY_ID": env["R2_ACCESS_KEY_ID"],
        "AWS_SECRET_ACCESS_KEY": env["R2_SECRET_ACCESS_KEY"],
        "AWS_DEFAULT_REGION": "auto",
        "AWS_PAGER": "",
    })
    endpoint = "https://%s.r2.cloudflarestorage.com" % env["R2_ACCOUNT_ID"]
    cmd = ["aws", "s3api"] + list(args) + ["--endpoint-url", endpoint, "--output", "json"]
    res = subprocess.run(cmd, env=run_env, capture_output=True, text=True)
    return res.returncode, res.stdout, res.stderr


def head(env, key):
    code, out, _ = aws(env, "head-object", "--bucket", env["R2_BUCKET_NAME"], "--key", key)
    return json.loads(out) if code == 0 else None


def read_source(source, public):
    """A source's bytes and content type: a path is a file of the public dir
    the game server served it from, anything else is downloaded."""
    if source.startswith("/"):
        if not public:
            raise SystemExit("%s is a path: pass --public" % source)
        with open(os.path.join(public, source.lstrip("/")), "rb") as f:
            return f.read(), "application/json" if source.endswith(".json") else ""
    return fetch(source)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("manifest")
    ap.add_argument("--env", required=True, help="go-server/.env with the R2_* keys")
    ap.add_argument("--out", required=True, help="directory to keep the downloaded files in")
    ap.add_argument("--mapping", required=True, help="TSV to write: table, name, source URL, key, bytes, sha256")
    ap.add_argument("--force", action="store_true", help="upload a key even when the bucket has it already")
    ap.add_argument("--public", help="go-server/public, for sources that are paths the game server served")
    args = ap.parse_args()

    env = load_env(args.env)
    with open(args.manifest, encoding="utf-8") as f:
        rows = [line.rstrip("\n").split("\t") for line in f if line.strip()]
    files = files_of(rows)

    mapping = []
    for table, name, fmt, source, stem in files:
        data, ctype_served = read_source(source, args.public)
        ext, ctype = check(data, ctype_served, fmt, source)
        key = "%s.%s" % (stem, ext)
        path = os.path.join(args.out, key)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
        digest = hashlib.sha256(data).hexdigest()

        existing = head(env, key)
        if existing and existing.get("ContentLength") == len(data) and not args.force:
            action = "kept"
        else:
            code, _, err = aws(env, "put-object", "--bucket", env["R2_BUCKET_NAME"], "--key", key,
                               "--body", path, "--content-type", ctype, "--cache-control", CACHE_CONTROL)
            if code != 0:
                sys.exit("upload of %s failed: %s" % (key, err.strip()))
            action = "uploaded"
        stored = head(env, key)
        if not stored or stored.get("ContentLength") != len(data) or stored.get("ContentType") != ctype:
            sys.exit("%s did not read back as %d bytes of %s: %s" % (key, len(data), ctype, stored))
        mapping.append((table, name, source, key, str(len(data)), digest))
        print("%-9s %8d  %s" % (action, len(data), key), flush=True)
        time.sleep(0.2)

    # Merged with a mapping already there: a key moved again is replaced,
    # every other row kept, so a later run adds to the record.
    merged = {}
    if os.path.exists(args.mapping):
        with open(args.mapping, encoding="utf-8") as f:
            for line in f.read().splitlines()[1:]:
                if line.strip():
                    merged[line.split("\t")[3]] = line.split("\t")
    for row in mapping:
        merged[row[3]] = list(row)
    with open(args.mapping, "w", encoding="utf-8") as f:
        f.write("table\tname\tsource_url\tkey\tbytes\tsha256\n")
        for row in merged.values():
            f.write("\t".join(row) + "\n")
    print("%d files in the bucket this run; %d in the mapping %s" % (len(mapping), len(merged), args.mapping))


if __name__ == "__main__":
    main()
