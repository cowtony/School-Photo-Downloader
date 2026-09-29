#!/usr/bin/env python3
"""Download all top-level attachments from a Toddle Journal feed."""

import argparse
import datetime as dt
import json
import mimetypes
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API_URL = "https://us-east-1-production-apis.toddleapp.com/graphql"
PAGE_SIZE = 5
TIMEOUT = 45
MAX_ATTEMPTS = 3
QUERY = """
query getCoursePostFeed($id: ID!, $after: String, $filters: PostFilterInput) {
  node(id: $id, type: COURSE) {
    ... on Course {
      posts(last: 5, after: $after, filters: $filters) {
        totalCount
        pageInfo { hasNextPage endCursor }
        edges {
          node {
            id
            title
            createdAt
            publishedAt
            attachments {
              id
              name
              type
              mimeType
              url
              signedUrl
              metadata
              displaySequence
            }
          }
        }
      }
    }
  }
}
""".strip()


class DownloadError(Exception):
    pass


def request_with_retries(request, purpose):
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            return urllib.request.urlopen(request, timeout=TIMEOUT)
        except urllib.error.HTTPError as exc:
            if exc.code in (401, 403):
                raise DownloadError(
                    "{} failed with HTTP {}: authentication was rejected; refresh TODDLE_TOKEN"
                    .format(purpose, exc.code)
                ) from exc
            if exc.code not in (408, 429) and not 500 <= exc.code < 600:
                raise DownloadError("{} failed with HTTP {}".format(purpose, exc.code)) from exc
            last_error = "HTTP {}".format(exc.code)
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            last_error = str(exc.reason) if isinstance(exc, urllib.error.URLError) else str(exc)
        if attempt < MAX_ATTEMPTS:
            time.sleep(2 ** (attempt - 1))
    raise DownloadError("{} failed after {} attempts: {}".format(purpose, MAX_ATTEMPTS, last_error))


def graphql_page(token, course_id, student_id, after):
    variables = {
        "id": course_id,
        "after": after,
        "filters": {
            "state": "PUBLISHED",
            "orderBy": "PUBLISHED_AT",
            "studentIds": student_id,
            "feedTypes": ["PORTFOLIO"],
        },
    }
    body = json.dumps({
        "operationName": "getCoursePostFeed",
        "query": QUERY,
        "variables": variables,
    }).encode("utf-8")
    request = urllib.request.Request(
        API_URL,
        data=body,
        headers={
            "Accept": "application/json",
            "Authorization": token,
            "Content-Type": "application/json",
            "User-Agent": "toddle-journal-downloader/1.0",
            "X-Tod-Source": "WEB",
        },
        method="POST",
    )
    with request_with_retries(request, "Toddle API request") as response:
        try:
            payload = json.load(response)
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise DownloadError("Toddle API returned invalid JSON") from exc

    candidates = payload if isinstance(payload, list) else [payload]
    errors = []
    for candidate in candidates:
        if not isinstance(candidate, dict):
            continue
        if candidate.get("errors"):
            errors.extend(candidate["errors"])
        data = candidate.get("data")
        node = data.get("node") if isinstance(data, dict) else None
        posts = node.get("posts") if isinstance(node, dict) else None
        if isinstance(posts, dict):
            return posts
    if errors:
        messages = [str(item.get("message", "unknown GraphQL error")) for item in errors if isinstance(item, dict)]
        raise DownloadError("Toddle GraphQL error: {}".format("; ".join(messages) or "unknown error"))
    raise DownloadError("Toddle API response did not contain a posts connection")


def fetch_all_posts(token, course_id, student_id):
    posts = []
    seen_post_ids = set()
    seen_cursors = set()
    after = None
    total_count = None

    while True:
        page = graphql_page(token, course_id, student_id, after)
        page_total = page.get("totalCount")
        if not isinstance(page_total, int) or page_total < 0:
            raise DownloadError("Toddle API returned an invalid totalCount")
        if total_count is None:
            total_count = page_total
        elif page_total != total_count:
            raise DownloadError("Toddle totalCount changed during pagination")

        edges = page.get("edges")
        page_info = page.get("pageInfo")
        if not isinstance(edges, list) or not isinstance(page_info, dict):
            raise DownloadError("Toddle API returned invalid pagination data")
        for edge in edges:
            post = edge.get("node") if isinstance(edge, dict) else None
            post_id = post.get("id") if isinstance(post, dict) else None
            if not post_id:
                raise DownloadError("Toddle API returned a post without an id")
            if post_id in seen_post_ids:
                raise DownloadError("Toddle pagination returned a duplicate post")
            seen_post_ids.add(post_id)
            posts.append(post)

        if not page_info.get("hasNextPage"):
            break
        cursor = page_info.get("endCursor")
        if not cursor:
            raise DownloadError("Toddle pagination has another page but no endCursor")
        if cursor in seen_cursors:
            raise DownloadError("Toddle pagination cursor repeated")
        seen_cursors.add(cursor)
        after = cursor

    if len(posts) != total_count:
        raise DownloadError(
            "Toddle pagination count mismatch: received {}, expected {}".format(len(posts), total_count)
        )
    return posts


def parse_post_time(post):
    value = post.get("publishedAt") or post.get("createdAt")
    if not isinstance(value, str) or not value:
        raise DownloadError("post {} has no usable timestamp".format(post.get("id", "<unknown>")))
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise DownloadError("post {} has an invalid timestamp".format(post.get("id", "<unknown>"))) from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return value, parsed


def expected_size(metadata):
    if isinstance(metadata, str):
        try:
            metadata = json.loads(metadata)
        except json.JSONDecodeError:
            return None
    if isinstance(metadata, dict):
        value = metadata.get("size")
        if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
            return value
        if isinstance(value, str) and value.isdigit():
            return int(value)
    return None


def safe_component(value, fallback, limit):
    value = str(value or "").replace("\\", "/").rsplit("/", 1)[-1]
    value = re.sub(r"[\x00-\x1f\x7f/:]", "_", value).strip(" .")
    return (value or fallback)[:limit]


def attachment_filename(attachment):
    original_name = safe_component(attachment.get("name"), "attachment", 140)
    if not Path(original_name).suffix:
        metadata = attachment.get("metadata")
        if isinstance(metadata, str):
            try:
                metadata = json.loads(metadata)
            except json.JSONDecodeError:
                metadata = None
        extension = metadata.get("fileExtension") if isinstance(metadata, dict) else None
        if not extension:
            extension = mimetypes.guess_extension(str(attachment.get("mimeType") or ""))
        if extension:
            original_name += "." + str(extension).lstrip(".").lower()
    attachment_id = safe_component(attachment.get("id"), "unknown-id", 80)
    return "{}_{}".format(attachment_id, original_name)


def attachment_category(attachment, filename):
    mime = str(attachment.get("mimeType") or "").lower()
    kind = str(attachment.get("type") or "").lower()
    guessed = mimetypes.guess_type(filename)[0] or ""
    if mime.startswith("image/") or "image" in kind or guessed.startswith("image/"):
        return "images"
    if mime.startswith("video/") or "video" in kind or guessed.startswith("video/"):
        return "videos"
    return "files"


def valid_file(path, size):
    try:
        actual = path.stat().st_size
    except FileNotFoundError:
        return False
    return actual > 0 and (size is None or actual == size)


def download_attachment(attachment, destination, size):
    url = attachment.get("signedUrl") or attachment.get("url")
    if not isinstance(url, str) or not url.startswith(("https://", "http://")):
        raise DownloadError("attachment {} has no usable download URL".format(attachment.get("id", "<unknown>")))
    destination.parent.mkdir(parents=True, exist_ok=True)
    part = destination.with_name(destination.name + ".part")
    try:
        part.unlink()
    except FileNotFoundError:
        pass

    request = urllib.request.Request(url, headers={"User-Agent": "toddle-journal-downloader/1.0"})
    try:
        with request_with_retries(request, "attachment download") as response, part.open("wb") as output:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                output.write(chunk)
        actual = part.stat().st_size
        if actual == 0:
            raise DownloadError("downloaded attachment is empty")
        if size is not None and actual != size:
            raise DownloadError("downloaded attachment size mismatch")
        os.replace(str(part), str(destination))
    except Exception:
        try:
            part.unlink()
        except FileNotFoundError:
            pass
        raise


def write_manifest(output_dir, posts):
    manifest_path = output_dir / "posts.json"
    temporary = manifest_path.with_name(manifest_path.name + ".part")
    output_dir.mkdir(parents=True, exist_ok=True)
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump({"posts": posts}, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.replace(str(temporary), str(manifest_path))


def main():
    parser = argparse.ArgumentParser(description="Download a Toddle Journal feed and its attachments")
    parser.add_argument("--course-id", required=True)
    parser.add_argument("--student-id", required=True)
    args = parser.parse_args()

    token = os.environ.get("TODDLE_TOKEN", "").strip()
    if not token:
        parser.error("TODDLE_TOKEN is required")
    if not token.lower().startswith("bearer "):
        token = "Bearer " + token

    script_dir = Path(__file__).resolve().parent
    output_dir = Path(os.environ.get("OUTPUT_DIR", str(script_dir / "downloads"))).expanduser().resolve()
    counts = {"posts": 0, "attachments": 0, "downloaded": 0, "existing": 0, "failed": 0}

    try:
        posts = fetch_all_posts(token, args.course_id, args.student_id)
        counts["posts"] = len(posts)
        manifest_posts = []
        for post in posts:
            timestamp, parsed_time = parse_post_time(post)
            month = parsed_time.strftime("%Y-%m")
            manifest_attachments = []
            attachments = post.get("attachments") or []
            if not isinstance(attachments, list):
                raise DownloadError("post {} has invalid attachments data".format(post.get("id", "<unknown>")))
            for attachment in attachments:
                counts["attachments"] += 1
                if not isinstance(attachment, dict) or not attachment.get("id"):
                    counts["failed"] += 1
                    print("ERROR: attachment metadata is invalid", file=sys.stderr)
                    continue
                attachment_id = safe_component(attachment["id"], "unknown-id", 80)
                filename = attachment_filename(attachment)
                category = attachment_category(attachment, filename)
                destination = output_dir / month / category / filename
                size = expected_size(attachment.get("metadata"))
                local_path = destination.relative_to(output_dir).as_posix()
                try:
                    if valid_file(destination, size):
                        counts["existing"] += 1
                    else:
                        download_attachment(attachment, destination, size)
                        counts["downloaded"] += 1
                    os.utime(str(destination), (parsed_time.timestamp(), parsed_time.timestamp()))
                except (DownloadError, OSError) as exc:
                    counts["failed"] += 1
                    local_path = None
                    print("ERROR: attachment {}: {}".format(attachment_id, exc), file=sys.stderr)
                manifest_attachments.append({
                    "id": attachment.get("id"),
                    "name": attachment.get("name"),
                    "type": attachment.get("type"),
                    "mimeType": attachment.get("mimeType"),
                    "metadata": attachment.get("metadata"),
                    "displaySequence": attachment.get("displaySequence"),
                    "localPath": local_path,
                })
            manifest_posts.append({
                "id": post.get("id"),
                "title": post.get("title"),
                "createdAt": post.get("createdAt"),
                "publishedAt": post.get("publishedAt"),
                "effectiveTime": timestamp,
                "attachments": manifest_attachments,
            })
        write_manifest(output_dir, manifest_posts)
    except DownloadError as exc:
        counts["failed"] += 1
        print("ERROR: {}".format(exc), file=sys.stderr)

    print(
        "Summary: posts={posts} attachments={attachments} downloaded={downloaded} "
        "existing={existing} failed={failed}".format(**counts)
    )
    return 1 if counts["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())
