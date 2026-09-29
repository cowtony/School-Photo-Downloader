# ProCare Photo & Video Downloader (Mac)

Bulk-download your child's ProCare photos and videos by month. Files are stored under `downloads/` with their original ProCare IDs and timestamps.

## Requirements

- Required: `curl`, `jq`, and `python3`
- Optional: `exiftool` for embedded photo/video timestamps and `SetFile` for macOS creation times

```bash
brew install jq exiftool
```

Without `exiftool`, downloads still work and filesystem modification times are set, but embedded EXIF/QuickTime timestamps are not written.

## 1. Get your token

1. Log in to ProCare in Chrome and open the **Photos** tab.
2. Open **Developer Tools → Network**, then refresh the page.
3. Select a request named `photos/?page=...` or use **Copy as cURL**.
4. Find `authorization: Bearer online_auth_...` in the request headers.
5. Copy only the value after `Bearer `.

Treat copied cURL commands and screenshots of request headers as secrets. Do not save the token in this repository or paste it into `fetch_procare.sh`.

Load it into the current terminal without adding it to shell history:

```bash
export PROCARE_TOKEN
read -s PROCARE_TOKEN
```

Paste the token, press Enter, and then run the downloader. Tokens expire; if the script reports HTTP 401/403, obtain a fresh one.

## 2. Run it

```bash
# One month
bash fetch_procare.sh 2024-11

# An inclusive month range
bash fetch_procare.sh 2024-08 2025-06
```

By default, files are written relative to the script location:

```text
downloads/
└── 2024-08/
    ├── photos/
    └── videos/
```

Set `OUTPUT_DIR` to choose another destination:

```bash
OUTPUT_DIR="$HOME/Pictures/ProCare" bash fetch_procare.sh 2024-08 2025-06
```

Afterward, remove the token from the terminal environment:

```bash
unset PROCARE_TOKEN
```

Re-running is safe: valid existing files are skipped. New downloads use temporary `.part` files and are renamed only after completion. API, pagination, or file download failures cause a non-zero exit status.
