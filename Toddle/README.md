# Toddle Journal Downloader

使用 Python 3 标准库下载指定课程、学生的全部 Toddle Journal 顶层附件。

## 安全准备令牌

从浏览器开发者工具的 Toddle GraphQL 请求中复制 `authorization` 请求头值，并只放入当前 shell 的环境变量。不要把令牌写入脚本、命令历史、配置文件或提交到 Git。

```bash
read -s TODDLE_TOKEN
export TODDLE_TOKEN
```

输入完整的 `Bearer ...` 请求头值后按回车。程序也接受不带 `Bearer ` 前缀的令牌，但始终只从 `TODDLE_TOKEN` 读取。

## 运行

从 Toddle 页面或相应 GraphQL 请求变量中确认课程 ID 和学生 ID，然后运行：

```bash
python3 fetch_toddle.py \
  --course-id '<COURSE_ID>' \
  --student-id '<STUDENT_ID>'
```

默认输出到脚本旁的 `downloads/`。可以用环境变量覆盖：

```bash
OUTPUT_DIR='/path/to/output' python3 fetch_toddle.py \
  --course-id '<COURSE_ID>' \
  --student-id '<STUDENT_ID>'
```

## 输出结构

```text
downloads/
├── posts.json
└── YYYY-MM/
    ├── images/
    ├── videos/
    └── files/
```

目录月份取文章的 `publishedAt`，缺失时使用 `createdAt`。文件名由附件 ID 和原始文件名组成以避免碰撞。`posts.json` 保存文章标题、时间、附件元数据和本地相对路径，不保存下载 URL 或凭据。

## 增量行为

重复运行时，非空且大小符合附件元数据的现有文件会跳过；缺失或无效文件会重新下载。下载先写入 `.part`，验证后原子替换目标文件；manifest 也原子更新。程序会遍历全部分页并核对 `totalCount`，任一 API、分页或附件下载失败都会以非零状态退出。
