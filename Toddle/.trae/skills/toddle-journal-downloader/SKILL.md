---
name: "toddle-journal-downloader"
description: "Downloads and verifies Toddle Journal posts and attachments. Invoke when a user asks to archive, resume, or validate a Toddle Journal download."
---

# Toddle Journal Downloader

Use `fetch_toddle.py` from the Toddle project directory (the directory containing this skill's `.trae` folder) to archive Journal posts and their top-level attachments.

## Required workflow

1. Confirm whether the user wants the complete Journal or a narrower course, student, or date range. Do not silently broaden the requested scope.
2. Confirm the course ID and student ID without placing personal data in documentation or source code.
3. Obtain authentication only through the `TODDLE_TOKEN` environment variable. Never embed, persist, echo, log, or report credentials, authorization headers, signed URLs, or other secrets.
4. Run the downloader with explicit `--course-id` and `--student-id` arguments. Use `OUTPUT_DIR` only when a non-default destination is requested.
5. Require complete cursor pagination and verify the fetched post count against GraphQL `totalCount`.
6. Verify the command exits successfully, attachment totals are plausible, `posts.json` matches the fetched posts, downloaded files are non-empty, and no `.part` files remain.
7. Report only non-sensitive aggregate results and actionable errors. If authentication is rejected, ask the user to refresh the environment variable rather than exposing or storing the token.

Never claim a complete archive if pagination, count validation, manifest writing, or any attachment download failed.
