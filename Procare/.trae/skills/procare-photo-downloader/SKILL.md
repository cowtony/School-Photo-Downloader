---
name: "procare-photo-downloader"
description: "Downloads and verifies ProCare photos and videos by month. Invoke when the user asks to archive, sync, or download ProCare media."
---

# ProCare Photo Downloader

Use `fetch_procare.sh` in the Procare project directory (the directory containing this skill's `.trae` folder) to download a single month or an inclusive month range.

## Workflow

1. Confirm the exact start and end months in `YYYY-MM` format. Clarify whether phrases such as “after May” include May and which year applies.
2. Check that `curl`, `jq`, and `python3` are available. `exiftool` is optional; without it, only filesystem timestamps are set.
3. Ask the user for a fresh Bearer token only when `PROCARE_TOKEN` is unavailable or authentication fails. The token is the value after `authorization: Bearer ` in a ProCare Photos API request.
4. Never write, print, commit, or repeat the token. Pass it only through the environment for the download command.
5. Run from the Procare project directory:

```bash
export PROCARE_TOKEN
read -s PROCARE_TOKEN
bash fetch_procare.sh <start-YYYY-MM> <end-YYYY-MM>
unset PROCARE_TOKEN
```

6. Monitor the command until it exits. If authentication fails, ask for a new token rather than retrying the same one.
7. Verify each month’s API totals against the completion summary. Require zero download failures and check that final files are non-empty.
8. Report monthly photo/video counts, failures, the output directory, and whether embedded metadata was written.

## Safety

- Treat tokens, copied cURL commands, request headers, and screenshots of browser developer tools as secrets.
- Do not save credentials in source files, documentation, screenshots, shell history, or commits.
- Do not delete existing downloads. Re-running is an incremental sync and skips valid existing files.
- Downloads are stored under `downloads/<YYYY-MM>/photos` and `downloads/<YYYY-MM>/videos`.
