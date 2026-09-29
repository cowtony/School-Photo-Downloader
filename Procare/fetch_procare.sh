#!/bin/bash
# 从 ProCare Connect 批量下载指定月份的照片和视频。
#
# 用法（先通过环境变量提供 token）：
#   PROCARE_TOKEN=... bash fetch_procare.sh <YYYY-MM>                  # 下载某一个月
#   PROCARE_TOKEN=... bash fetch_procare.sh <起始 YYYY-MM> <结束 YYYY-MM>  # 下载多个月（含两端）
#
# 例：
#   bash fetch_procare.sh 2024-11
#   bash fetch_procare.sh 2024-08 2025-06
#
# 输出结构：
#   downloads/<YYYY-MM>/
#   ├── photos/   全部照片 (UUID.jpg)
#   └── videos/   全部视频 (UUID.mp4 / .mov 等)
#
# 文件名保留 ProCare 原始 UUID；
# 文件修改时间按 API 返回的 created_at 设置；安装可选工具后也会写入创建时间和媒体元数据。
#
# 重复运行安全：有效的已有文件会跳过，可用作增量同步。
#
# 必需：curl, jq, python3；可选：exiftool, SetFile
# 安装可选工具：brew install exiftool

set -euo pipefail

# ============================================================
# 配置
# ============================================================
TOKEN="${PROCARE_TOKEN:-}"
ORIGIN="https://schools.procareconnect.com"
PHOTOS_API="https://api-school.procareconnect.com/api/web/parent/photos/"
VIDEOS_API="https://api-school.procareconnect.com/api/web/parent/videos/"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/downloads}"

if [ -z "$TOKEN" ]; then
    echo "错误：请通过 PROCARE_TOKEN 环境变量提供 Bearer token。" >&2
    echo "请先运行：export PROCARE_TOKEN; read -s PROCARE_TOKEN" >&2
    exit 1
fi

CURL_API_ARGS=(
    --silent --show-error --fail-with-body --location
    --connect-timeout 10 --max-time 120
    --retry 3 --retry-delay 2
)
CURL_MEDIA_ARGS=(
    --silent --show-error --fail --location
    --connect-timeout 10 --max-time 600
    --retry 3 --retry-delay 2
)

# ============================================================
# 检查依赖
# ============================================================
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
for cmd in curl jq python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "错误：未找到 $cmd，请先安装：brew install $cmd"
        exit 1
    fi
done

EXIFTOOL_BIN=$(command -v exiftool || true)
if [ -z "$EXIFTOOL_BIN" ]; then
    echo "提示：未找到 exiftool，将只改文件系统时间，不写 EXIF/QuickTime 元数据。"
    echo "建议安装：brew install exiftool"
    echo
fi

# ============================================================
# 参数解析
# ============================================================
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "用法:"
    echo "  $0 <YYYY-MM>                       # 下载某一个月"
    echo "  $0 <起始 YYYY-MM> <结束 YYYY-MM>  # 下载多个月（含两端）"
    echo
    echo "例:"
    echo "  $0 2024-11"
    echo "  $0 2024-08 2025-06"
    exit 1
fi

START_MONTH="$1"
END_MONTH="${2:-$1}"

# 校验月份格式和值
for m in "$START_MONTH" "$END_MONTH"; do
    if ! [[ "$m" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]] || \
       ! python3 -c "import datetime; datetime.datetime.strptime('$m', '%Y-%m')" 2>/dev/null; then
        echo "错误：月份必须是有效的 YYYY-MM，比如 2024-11，但你给的是: $m" >&2
        exit 1
    fi
done

if [[ "$START_MONTH" > "$END_MONTH" ]]; then
    echo "错误：起始月份不能晚于结束月份。" >&2
    exit 1
fi

# ============================================================
# 工具函数
# ============================================================

urlenc() {
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

# 计算某个月的最后一天（YYYY-MM-DD）
month_last_day() {
    local ym="$1"
    python3 -c "
import calendar
y, m = map(int, '$ym'.split('-'))
last = calendar.monthrange(y, m)[1]
print(f'{y:04d}-{m:02d}-{last:02d}')
"
}

# 下个月（YYYY-MM）
next_month() {
    local ym="$1"
    python3 -c "
y, m = map(int, '$ym'.split('-'))
m += 1
if m == 13:
    y += 1; m = 1
print(f'{y:04d}-{m:02d}')
"
}

# 调用照片或视频 API
# 用法：call_api <photos|videos> <page> <date_from> <date_to>
call_api() {
    local kind="$1" page="$2" from="$3" to="$4"
    local api filter_key
    if [ "$kind" = "photos" ]; then
        api="$PHOTOS_API"
        filter_key="photo"
    else
        api="$VIDEOS_API"
        filter_key="video"
    fi
    local from_enc to_enc body_file status
    from_enc=$(urlenc "$from")
    to_enc=$(urlenc "$to")
    body_file=$(mktemp)

    if ! status=$(curl "${CURL_API_ARGS[@]}" -X GET \
        -o "$body_file" -w "%{http_code}" \
        "${api}?page=${page}&filters%5B${filter_key}%5D%5Bdatetime_from%5D=${from_enc}&filters%5B${filter_key}%5D%5Bdatetime_to%5D=${to_enc}" \
        -H "accept: application/json, text/plain, */*" \
        -H "authorization: Bearer ${TOKEN}" \
        -H "origin: ${ORIGIN}" \
        -H "referer: ${ORIGIN}/" \
        -H "user-agent: Mozilla/5.0"); then
        if [ "$status" = "401" ] || [ "$status" = "403" ]; then
            echo "错误：Bearer token 无效或已过期，请重新获取。" >&2
        else
            echo "错误：API 请求失败（HTTP ${status:-未知}）。" >&2
        fi
        rm -f "$body_file"
        return 1
    fi

    cat "$body_file"
    rm -f "$body_file"
}

# 把 ISO 8601 时间转成各种工具需要的格式
# 输出 4 行：touch_fmt / setfile_fmt / exif_local / exif_utc
parse_time() {
    python3 - "$1" <<'PY'
import sys, datetime
s = sys.argv[1]
try:
    dt = datetime.datetime.fromisoformat(s)
except ValueError:
    dt = datetime.datetime.fromisoformat(s.split('.')[0] + s[-6:])
local = dt.astimezone()
utc   = dt.astimezone(datetime.timezone.utc)
print(local.strftime("%Y%m%d%H%M.%S"))     # touch -t
print(local.strftime("%m/%d/%Y %H:%M:%S")) # SetFile
print(local.strftime("%Y:%m:%d %H:%M:%S")) # exiftool（图片用本地）
print(utc.strftime("%Y:%m:%d %H:%M:%S"))   # exiftool（视频 QuickTime 用 UTC）
PY
}

# 设置文件时间（mtime + birthtime）
set_fs_times() {
    local file="$1" touch_fmt="$2" setfile_fmt="$3"
    touch -t "$touch_fmt" "$file"
    if command -v SetFile >/dev/null 2>&1; then
        SetFile -d "$setfile_fmt" -m "$setfile_fmt" "$file" 2>/dev/null || true
    fi
}

# ============================================================
# 主循环：下载一个月的照片
# ============================================================
download_photos_one_month() {
    local ym="$1" out_dir="$2"
    local date_from="${ym}-01 00:00"
    local date_to="$(month_last_day "$ym") 23:59"

    mkdir -p "$out_dir"
    echo "  [Photos] 请求 page 1 ..."
    local resp
    resp=$(call_api photos 1 "$date_from" "$date_to")

    if ! echo "$resp" | jq -e '(.error | not) and (.total | type == "number") and (.per_page | type == "number") and (.photos | type == "array")' >/dev/null 2>&1; then
        echo "  [Photos] API 返回了无效数据。" >&2
        return 1
    fi

    local total per_page pages
    total=$(echo "$resp"   | jq -r '.total // 0')
    per_page=$(echo "$resp" | jq -r '.per_page // 30')

    if [ "$total" = "0" ]; then
        echo "  [Photos] $ym 无照片"
        return 0
    fi

    pages=$(( (total + per_page - 1) / per_page ))
    echo "  [Photos] $ym 共 $total 张（$pages 页）"

    local all_json
    all_json=$(mktemp)
    echo "$resp" | jq -c '.photos[]' > "$all_json"

    local p page_resp actual
    for ((p=2; p<=pages; p++)); do
        echo "  [Photos] 请求 page $p ..."
        page_resp=$(call_api photos "$p" "$date_from" "$date_to")
        if ! echo "$page_resp" | jq -e '(.photos | type == "array")' >/dev/null 2>&1; then
            echo "  [Photos] 第 $p 页返回了无效数据。" >&2
            rm -f "$all_json"
            return 1
        fi
        echo "$page_resp" | jq -c '.photos[]' >> "$all_json"
        sleep 0.3
    done

    actual=$(wc -l < "$all_json" | tr -d ' ')
    if [ "$actual" -ne "$total" ]; then
        echo "  [Photos] 分页记录数不一致：API 报告 $total，实际收到 $actual。" >&2
        rm -f "$all_json"
        return 1
    fi

    local ok=0 fail=0 already=0 skip=0
    while IFS= read -r line; do
        local id main_url created is_video
        id=$(echo "$line"        | jq -r '.id')
        main_url=$(echo "$line"  | jq -r '.main_url')
        created=$(echo "$line"   | jq -r '.created_at')
        is_video=$(echo "$line"  | jq -r '.is_video')

        if [ "$is_video" = "true" ]; then
            skip=$((skip+1))
            continue
        fi

        # 从 main_url 提取真实文件名
        local file_name
        file_name=$(echo "$main_url" | sed -E 's|.*/main/([^?]+)\?.*|\1|')
        [ -z "$file_name" ] || [ "$file_name" = "$main_url" ] && file_name="${id}.jpg"

        local out_path="$out_dir/$file_name" tmp_path="${out_dir}/${file_name}.part"
        if [ -s "$out_path" ]; then
            already=$((already+1))
            continue
        fi
        rm -f "$out_path" "$tmp_path"

        if ! curl "${CURL_MEDIA_ARGS[@]}" -o "$tmp_path" "$main_url" || [ ! -s "$tmp_path" ]; then
            echo "  [Photos] [fail] $file_name"
            rm -f "$tmp_path"
            fail=$((fail+1))
            continue
        fi
        mv "$tmp_path" "$out_path"

        # 解析时间
        local OLDIFS="$IFS"
        IFS=$'\n'
        local fmt_lines
        fmt_lines=($(parse_time "$created"))
        IFS="$OLDIFS"
        local touch_fmt="${fmt_lines[0]}" setfile_fmt="${fmt_lines[1]}" exif_local="${fmt_lines[2]}"

        # 写 EXIF（先），再设文件时间
        if [ -n "$EXIFTOOL_BIN" ] && ! "$EXIFTOOL_BIN" -overwrite_original -q \
            -DateTimeOriginal="$exif_local" \
            -CreateDate="$exif_local" \
            -ModifyDate="$exif_local" \
            "$out_path" >/dev/null 2>&1; then
            echo "  [Photos] 警告：无法写入元数据 $file_name" >&2
        fi
        set_fs_times "$out_path" "$touch_fmt" "$setfile_fmt"

        ok=$((ok+1))
    done < "$all_json"

    rm -f "$all_json"
    echo "  [Photos] 完成：新下 $ok / 已存在 $already / 跳过视频 $skip / 失败 $fail"
    if [ "$fail" -gt 0 ]; then
        return 1
    fi
}

# ============================================================
# 主循环：下载一个月的视频
# ============================================================
download_videos_one_month() {
    local ym="$1" out_dir="$2"
    local date_from="${ym}-01 00:00"
    local date_to="$(month_last_day "$ym") 23:59"

    mkdir -p "$out_dir"
    echo "  [Videos] 请求 page 1 ..."
    local resp
    resp=$(call_api videos 1 "$date_from" "$date_to")

    if ! echo "$resp" | jq -e '(.error | not) and (.total | type == "number") and (.per_page | type == "number") and (.videos | type == "array")' >/dev/null 2>&1; then
        echo "  [Videos] API 返回了无效数据。" >&2
        return 1
    fi

    local total per_page pages
    total=$(echo "$resp"    | jq -r '.total // 0')
    per_page=$(echo "$resp" | jq -r '.per_page // 30')

    if [ "$total" = "0" ]; then
        echo "  [Videos] $ym 无视频"
        return 0
    fi

    pages=$(( (total + per_page - 1) / per_page ))
    echo "  [Videos] $ym 共 $total 个（$pages 页）"

    local all_json
    all_json=$(mktemp)
    echo "$resp" | jq -c '.videos[]' > "$all_json"

    local p page_resp actual
    for ((p=2; p<=pages; p++)); do
        echo "  [Videos] 请求 page $p ..."
        page_resp=$(call_api videos "$p" "$date_from" "$date_to")
        if ! echo "$page_resp" | jq -e '(.videos | type == "array")' >/dev/null 2>&1; then
            echo "  [Videos] 第 $p 页返回了无效数据。" >&2
            rm -f "$all_json"
            return 1
        fi
        echo "$page_resp" | jq -c '.videos[]' >> "$all_json"
        sleep 0.3
    done

    actual=$(wc -l < "$all_json" | tr -d ' ')
    if [ "$actual" -ne "$total" ]; then
        echo "  [Videos] 分页记录数不一致：API 报告 $total，实际收到 $actual。" >&2
        rm -f "$all_json"
        return 1
    fi

    local ok=0 fail=0 already=0
    while IFS= read -r line; do
        local id video_url created
        id=$(echo "$line"        | jq -r '.id')
        video_url=$(echo "$line" | jq -r '.video_file_url')
        created=$(echo "$line"   | jq -r '.created_at')

        [ -z "$video_url" ] || [ "$video_url" = "null" ] && continue

        # 探测 Content-Type 决定扩展名
        local content_type ext
        content_type=$(curl "${CURL_MEDIA_ARGS[@]}" -I "$video_url" 2>/dev/null \
            | awk -F': ' 'tolower($1)=="content-type"{print $2}' | tr -d '\r\n' || true)
        case "$content_type" in
            video/mp4)        ext="mp4" ;;
            video/quicktime)  ext="mov" ;;
            video/webm)       ext="webm" ;;
            video/x-m4v)      ext="m4v" ;;
            video/*)          ext="${content_type#video/}" ;;
            *)                ext="mp4" ;;
        esac

        local out_path="$out_dir/${id}.${ext}" tmp_path="${out_dir}/${id}.${ext}.part"
        if [ -s "$out_path" ]; then
            already=$((already+1))
            continue
        fi
        rm -f "$out_path" "$tmp_path"

        echo -n "  [Videos] 下载 ${id}.${ext} ..."
        if ! curl "${CURL_MEDIA_ARGS[@]}" -o "$tmp_path" "$video_url" || [ ! -s "$tmp_path" ]; then
            echo " fail"
            rm -f "$tmp_path"
            fail=$((fail+1))
            continue
        fi
        mv "$tmp_path" "$out_path"
        local size
        size=$(du -h "$out_path" | cut -f1)
        echo " ok ($size)"

        # 解析时间
        local OLDIFS="$IFS"
        IFS=$'\n'
        local fmt_lines
        fmt_lines=($(parse_time "$created"))
        IFS="$OLDIFS"
        local touch_fmt="${fmt_lines[0]}" setfile_fmt="${fmt_lines[1]}" exif_utc="${fmt_lines[3]}"

        # MP4 元数据按 QuickTime 标准用 UTC
        if [ -n "$EXIFTOOL_BIN" ] && ! "$EXIFTOOL_BIN" -overwrite_original -q \
            -CreateDate="$exif_utc" \
            -ModifyDate="$exif_utc" \
            -TrackCreateDate="$exif_utc" \
            -TrackModifyDate="$exif_utc" \
            -MediaCreateDate="$exif_utc" \
            -MediaModifyDate="$exif_utc" \
            "$out_path" >/dev/null 2>&1; then
            echo "  [Videos] 警告：无法写入元数据 ${id}.${ext}" >&2
        fi
        set_fs_times "$out_path" "$touch_fmt" "$setfile_fmt"

        ok=$((ok+1))
    done < "$all_json"

    rm -f "$all_json"
    echo "  [Videos] 完成：新下 $ok / 已存在 $already / 失败 $fail"
    if [ "$fail" -gt 0 ]; then
        return 1
    fi
}

# ============================================================
# 主入口：遍历月份
# ============================================================
echo "时间范围：$START_MONTH 到 $END_MONTH"
echo

cur="$START_MONTH"
while :; do
    echo "================ $cur ================"
    download_photos_one_month "$cur" "$OUTPUT_DIR/${cur}/photos"
    download_videos_one_month "$cur" "$OUTPUT_DIR/${cur}/videos"
    echo

    if [ "$cur" = "$END_MONTH" ]; then
        break
    fi
    cur=$(next_month "$cur")
    # 安全保护：避免月份格式错误造成死循环
    if [[ "$cur" > "9999-12" ]]; then
        echo "异常：月份计算溢出"
        exit 1
    fi
done

echo "全部完成！"
