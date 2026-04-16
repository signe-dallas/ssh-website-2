#!/usr/bin/env python3
"""Mirror a website's same-origin HTML/CSS/JS/images for local editing."""

from __future__ import annotations

import argparse
import json
import pathlib
import posixpath
import re
import sys
import urllib.parse
import urllib.request
from collections import deque
from html.parser import HTMLParser

ASSET_ATTRS = {
    "a": "href",
    "link": "href",
    "script": "src",
    "img": "src",
    "source": "src",
    "video": "src",
    "audio": "src",
}

HTML_EXTENSIONS = {"", ".html", ".htm", ".php", ".asp", ".aspx"}
CSS_URL_RE = re.compile(r"url\(([^)]+)\)", re.IGNORECASE)


class LinkExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.links: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        target_attr = ASSET_ATTRS.get(tag.lower())
        if not target_attr:
            return
        for key, value in attrs:
            if key.lower() == target_attr and value:
                self.links.append(value.strip())
                break


def normalize_url(base: str, candidate: str) -> str | None:
    if not candidate:
        return None
    if candidate.startswith(("mailto:", "tel:", "javascript:", "data:")):
        return None

    candidate = candidate.split("#", 1)[0].strip()
    if not candidate:
        return None

    absolute = urllib.parse.urljoin(base, candidate)
    parsed = urllib.parse.urlparse(absolute)
    if parsed.scheme not in {"http", "https"}:
        return None

    cleaned = parsed._replace(fragment="")
    return urllib.parse.urlunparse(cleaned)


def is_same_origin(url: str, origin: urllib.parse.ParseResult) -> bool:
    parsed = urllib.parse.urlparse(url)
    return (parsed.scheme, parsed.netloc) == (origin.scheme, origin.netloc)


def local_path_for_url(url: str, root: pathlib.Path, origin: urllib.parse.ParseResult) -> pathlib.Path:
    parsed = urllib.parse.urlparse(url)
    rel_path = urllib.parse.unquote(parsed.path or "/")

    if rel_path.endswith("/"):
        rel_path += "index.html"

    ext = pathlib.PurePosixPath(rel_path).suffix.lower()
    if ext in HTML_EXTENSIONS:
        if not pathlib.PurePosixPath(rel_path).suffix:
            rel_path = f"{rel_path}.html"

    if parsed.query:
        safe_query = re.sub(r"[^a-zA-Z0-9._-]+", "_", parsed.query)[:80]
        base, ext2 = posixpath.splitext(rel_path)
        rel_path = f"{base}__q_{safe_query}{ext2 or '.html'}"

    rel_path = rel_path.lstrip("/")
    rel = pathlib.PurePosixPath(rel_path)

    # Keep host in output in case of future extension to multi-origin.
    return root / origin.netloc / pathlib.Path(rel)


def fetch(url: str, timeout: int = 30) -> tuple[bytes, str]:
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 (compatible; site-mirror/1.0)",
            "Accept": "*/*",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout) as response:  # nosec B310
        body = response.read()
        ctype = response.headers.get("Content-Type", "")
    return body, ctype


def decode_bytes(body: bytes, fallback: str = "utf-8") -> str:
    for enc in ("utf-8", "utf-16", "latin-1", fallback):
        try:
            return body.decode(enc)
        except UnicodeDecodeError:
            continue
    return body.decode("utf-8", errors="replace")


def extract_css_urls(css_text: str) -> list[str]:
    results: list[str] = []
    for raw in CSS_URL_RE.findall(css_text):
        val = raw.strip().strip("\"'")
        if val:
            results.append(val)
    return results


def should_parse_html(url: str, content_type: str, body: bytes) -> bool:
    if "text/html" in content_type.lower():
        return True
    if "application/xhtml+xml" in content_type.lower():
        return True

    # Fallback: basic sniff for HTML documents.
    head = body[:500].lower()
    return b"<html" in head or b"<!doctype html" in head


def should_parse_css(url: str, content_type: str) -> bool:
    return (
        "text/css" in content_type.lower()
        or urllib.parse.urlparse(url).path.lower().endswith(".css")
    )


def mirror(start_url: str, output_dir: pathlib.Path, max_pages: int) -> dict[str, int]:
    origin = urllib.parse.urlparse(start_url)
    queue: deque[str] = deque([start_url])
    seen: set[str] = set()

    counts = {"downloaded": 0, "html": 0, "assets": 0, "errors": 0}

    while queue:
        url = queue.popleft()
        if url in seen:
            continue
        if len(seen) >= max_pages:
            break

        seen.add(url)
        try:
            body, content_type = fetch(url)
        except Exception as exc:  # pylint: disable=broad-except
            print(f"[WARN] failed: {url} -> {exc}")
            counts["errors"] += 1
            continue

        path = local_path_for_url(url, output_dir, origin)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(body)

        counts["downloaded"] += 1

        parse_html = should_parse_html(url, content_type, body)
        parse_css = should_parse_css(url, content_type)

        if parse_html:
            counts["html"] += 1
            text = decode_bytes(body)
            parser = LinkExtractor()
            parser.feed(text)
            raw_links = parser.links
        else:
            raw_links = []

        if parse_css:
            text = decode_bytes(body)
            raw_links.extend(extract_css_urls(text))

        for raw in raw_links:
            normalized = normalize_url(url, raw)
            if not normalized or normalized in seen:
                continue
            if not is_same_origin(normalized, origin):
                continue
            queue.append(normalized)

        if not parse_html:
            counts["assets"] += 1

        print(f"[OK] {url} -> {path}")

    return counts


def main() -> int:
    parser = argparse.ArgumentParser(description="Mirror a site for local editing")
    parser.add_argument("url", help="Start URL, e.g. https://example.com/")
    parser.add_argument(
        "--output",
        default="site-mirror",
        help="Directory to write mirrored files (default: site-mirror)",
    )
    parser.add_argument(
        "--max-pages",
        type=int,
        default=1500,
        help="Safety limit for downloaded URLs (default: 1500)",
    )

    args = parser.parse_args()
    start = normalize_url(args.url, "")
    if not start:
        print("Invalid URL")
        return 1

    out = pathlib.Path(args.output).resolve()
    out.mkdir(parents=True, exist_ok=True)

    stats = mirror(start, out, args.max_pages)
    summary_path = out / "mirror-summary.json"
    summary_path.write_text(json.dumps(stats, indent=2), encoding="utf-8")

    print("\nMirror complete")
    print(json.dumps(stats, indent=2))
    print(f"Summary: {summary_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
