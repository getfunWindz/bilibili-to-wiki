---
name: bilibili-to-wiki
version: 1.0.0
author: getfunWindz
license: MIT
description: |
  将 B 站视频（链接/BV号/av号）作为素材消化进 LLM Wiki 知识库的编排 skill。
  当用户意图是「把某 B 站视频加入知识库 / 消化这个视频 / 视频入库」时使用。
  它只做编排（不重复实现功能）：①bilibili-learn 抓取字幕 →
  ②glossary 术语勘误（clean）→ ③llm-wiki digest 入库 → ④反哺（absorb）→ ⑤重建图谱。
  注意路由：仅「总结/出学习报告」意图 → 用 bilibili-learn；素材已是本地文件/文本 →
  直接用 llm-wiki；素材是 B 站视频且用户提到知识库 → 必须用本 skill。
metadata:
  workflow: bilibili → 知识库
  depends: [bilibili-learn, llm-wiki]
---

# bilibili-to-wiki — B 站视频入库编排

> 一句话职责：把 B 站视频变成 llm-wiki 知识库里的素材（字幕→勘误→digest→图谱），
> **不生成学习报告**（那是 bilibili-learn 的独立职能，需要报告时让用户走 bilibili-learn）。

## 触发与排除

**触发（用户说以下任何一句，或等价意思）**：
- "把 BV1xxxxxx 加进知识库 / 消化进知识库 / 入库"
- "B 站视频 加入我的 nlmm-wiki / wiki"
- "消化这个视频"（上下文里有 B 站链接 / BV 号时）
- 直接丢一个 B 站链接/BV号 + 提到"知识库"

**排除（不要接管，路由回原 skill）**：
- 用户只说"总结这个视频 / 出学习报告 / 整理成笔记" → bilibili-learn
- 用户给的是本地文件 / 纯文本 / 网页文章 → llm-wiki 或对应 skill
- 知识库还不存在（无 `~/.llm-wiki-path`）→ **先跑 llm-wiki 的 init 初始化知识库**，再继续

## 前置检查

```bash
# 1. 确认两个依赖 skill 与知识库路径存在
[ -f ~/.pi/agent/skills/bilibili-learn/scripts/bili.py ] || { echo "bilibili-learn 缺失"; exit 1; }
[ -d ~/.pi/agent/skills/llm-wiki/scripts ] || { echo "llm-wiki 缺失"; exit 1; }
KB=$(cat ~/.llm-wiki-path 2>/dev/null) && [ -n "$KB" ] || { echo "知识库未初始化（先跑 llm-wiki init）"; exit 1; }
# 2. glossary 表必须存在（勘误依赖）
[ -f ~/.pi/agent/skills/bilibili-learn/references/glossary.json ] || exit 1
```

## 工作流 A：单个视频入库（主路径）

### Step 1｜抓取字幕（bilibili-learn）

```bash
python -X utf8 ~/.pi/agent/skills/bilibili-learn/scripts/bili.py run <视频> --out <tmp_dir> [--pages N]
```

- `<视频>`：链接 / BV 号 / av 号（让 bilibili-learn 自己解析）
- 产物：`<tmp_dir>/<UP主>/<日期>_<标题>/subtitle.txt` + `video_info.json`
- **检查 `subtitle.txt` 存在**；不存在 → 查 `video_info.json` 的 `subtitle_source`：
  - 若为 `whisper`，转写质量更低 → Step 2 的勘误关**必须执行**，并在最终汇报里标注「Whisper 转写、建议人工抽检」
  - 若为空/失败 → 提示用户（限流建议稍后重试或改用链接输入），**不要硬编造内容**

### Step 2｜术语勘误关（glossary clean）——**不可跳过**

```bash
python -X utf8 ~/.pi/agent/skills/bilibili-learn/scripts/glossary.py \
  clean "<subtitle.txt>" --out "<tmp_dir>/corrected.txt"
```

- 脚本按 `glossary.json` 的 `_aliases` 替换已知勘误（stt_error/naming 自动替换）
- 输出三行：替换 N 类 M 处 / 存疑清单 / 写盘成功
- **存疑清单非空时**：把存疑词列给用户（一句话确认，或直接标 uncertain 入库），
  然后用户回复确认与否——**不询问会违反「不过度自动化」原则**。确认后：
  ```bash
  python -X utf8 ~/.pi/agent/skills/bilibili-learn/scripts/glossary.py alias "<错误>" "<正确>"   # 已确认的登记为勘误
  # 或保持 uncertain（不需要人工介入时）直接继续
  ```
- 未命中勘误的错词由 LLM 在 Step 3 的分析中处理（看到明显错误在实体名上修正，不改原文）

### Step 3｜复制 corrected 稿进知识库 raw

```bash
cp "<tmp_dir>/corrected.txt" "$KB/raw/notes/$(date +%F)-<标题>.md"
```

- 文件名：`YYYY-MM-DD-<短标题>.md`（无空格用连字符）
- **同时**写一个 front matter 头到这个 raw 文件（llm-wiki 读取友好）：

```markdown
---
source_type: 视频
source_url: <原始链接>
transcript_quality: subtitle_corrected / whisper_corrected
corrections_count: <M>
uncertain_terms: [<存疑词>]
---
```

### Step 4｜digest（llm-wiki）

对 raw 文件执行 llm-wiki 的 ingest 工作流（读 `~/.pi/agent/skills/llm-wiki/SKILL.md` 的「工作流 2」）：
- 先 `cache.sh check` → HIT 则告诉用户「已消化过，复用已有结果」并直接跳 Step 5
- MISS → step1 JSON（validate-step1.sh）→ 页面生成（source/entity/topic 页）→ 更新 index.md / log.md
- **注意**：digest 时把「原文音频里 Q 听到的」错词在 page 里**只写正确拼写**（实体名规范化），
  原始错词留 raw 与 tmp 作为证据，不改写。

### Step 5｜反哺 + 收尾

```bash
python -X utf8 ~/.pi/agent/skills/bilibili-learn/scripts/glossary.py absorb "$KB/wiki"   # 新术语沉淀
bash ~/.pi/agent/skills/llm-wiki/scripts/build-graph-data.sh "$KB"                        # 图谱数据
bash ~/.pi/agent/skills/llm-wiki/scripts/build-graph-html.sh "$KB"                        # 交互图谱
printf '%s\n' "$(date '+%F %T') $VIDEO -> digest OK, corrections $M, uncertain $K" >> ~/.pi/logs/bili-to-wiki.log
```

### Step 6｜汇报（固定格式，三行总结）

```
已入库：<视频标题>（<链接>）
- 新增页面：sources +N / entities +N / topics +N（列出新增页名）
- 术语勘误：M 处替换（列出 2-3 个例子）；存疑 K 个（若>0 列出并说明已待确认）
- 图谱已更新：nodes N / edges M（双击 kb/wiki/knowledge-graph.html 查看）
```

## 工作流 B：收藏夹批量

```bash
python -X utf8 ~/.pi/agent/skills/bilibili-learn/scripts/bili.py favs-scan <收藏夹> --priority --out <tmp>
```

- 展示推荐顺序（播放量优先），用户确认后对每个视频执行工作流 A
- 每 3 个暂停一次，问用户继续与否（防 token/时间失控）

## 工作流 C：Whisper 兜底（无字幕视频）

- bili.py 会自动 Whisper；转写质量差 → Step 2 必须执行 + 汇报标注
- 用户可追加 `--no-whisper` 明确拒绝转写（则本 skill 中止并说明）

## 错误分支表

| 现象 | 处理 |
|------|------|
| `no_subtitle` 且 user 拒绝 whisper | 中止，向用户说明，建议提供手动文本 |
| `whisper_failed` | 重试一次；仍失败中止，说明原因 |
| 有字幕但 clean 后存疑 >5 | 批量确认（show list, 用户批量选），一次性 alias |
| digest cache HIT | 直接复用（Step 4 短路），汇报「复用已有结果」 |
| glossary.json 缺失/损坏 | 初始化空表 + 提示用户（`python glossary.py list` 确认） |
| 限流/风控（bili.py 报错） | 提示用户改用链接输入或稍后重试 |

## 输出规范

- **所有**面向用户的输出用中文
- 入库成功后显示三行总结（Step 6）
- 不输出中间 JSON、长日志（日志落文件 `~/.pi/logs/bili-to-wiki.log`）

## 反例（避免误接管）

用户说「总结一下这个视频讲了什么」→ 不接管，路由 bilibili-learn（它能出学习报告）。
用户说「把这篇 PDF 加进知识库」→ 不接管，路由 llm-wiki（本地文件直读）。
