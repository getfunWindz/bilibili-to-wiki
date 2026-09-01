# bilibili-to-wiki

> **B 站视频 → LLM Wiki 知识库桥接 Skill**：把 B 站视频作为素材消化进个人 LLM Wiki 知识库的编排 Skill。
>
> 它只做编排（不重复实现功能）：bilibili-learn 抓取字幕 → glossary 术语勘误 → llm-wiki digest 入库 → 反哺（absorb）→ 重建知识图谱。

**版本**：1.0.0 ｜ 作者：getfunWindz ｜ 许可证：MIT

---

## 为什么需要这个 Skill

| 问题 | 说明 |
|------|------|
| 跨会话失效 | bilibili-learn 与 llm-wiki 是两个独立 Skill，**编排流程只存在于单次对话上下文**。换新会话后，agent 不知道「B 站视频 → 知识库」的完整流程 |
| 触发词重叠 | 用户说「把这个视频消化进知识库」时，可能被 bilibili-learn（只会总结出报告）或 llm-wiki（处理不了 B 站链接）误接管 |
| 字幕噪声污染 | B 站官方字幕 / Whisper 转写存在识别错误（如 `ATHROPIC→Anthropic`、`grab→grep`），不校验就会把错字灌进知识库 |

## 功能概览

- **抓取**：调用 bilibili-learn 的 `bili.py run`（字幕优先，Whisper 兜底）
- **勘误**：调用 bilibili-learn 的 `glossary.py clean`，按 `glossary.json._aliases` 替换已知识别错误；未命中的存疑词走人工确认
- **入库**：corrected 稿复制到知识库 `raw/notes/`（带 front matter 元信息），agent 命名
- **消化**：按 llm-wiki ingest 工作流执行（Step1 结构化分析 → 页面生成 → index/log 更新）
- **反哺**：`glossary.py absorb` 把知识库实体页/主题页新术语沉淀回术语表（双向闭环）
- **图谱**：重建 `wiki/knowledge-graph.html` 离线交互图谱

## 目录结构

```
bilibili-to-wiki/
├── SKILL.md                    # Skill 主文件（触发/排除/工作流/错误分支/输出规范）
└── scripts/
    └── ingest-pipeline.sh      # 主编排脚本：抓取+勘误（命名与 digest 由 agent 执行）
```

## 依赖（按编排顺序）

| 依赖 | 位置 | 职责 |
|------|------|------|
| **bilibili-learn** | `~/.pi/agent/skills/bilibili-learn/` | B 站内容获取（`bili.py run`）、glossary 术语库（`glossary.py` alias/clean/absorb） |
| **llm-wiki** | `~/.pi/agent/skills/llm-wiki/` | 知识库（`init-wiki.sh`、`cache.sh`、`validate-step1.sh`、`create-source-page.sh`、`build-graph-data/html.sh`） |
| **jq** | PATH | 图谱构建脚本依赖 |
| **Node.js** | 系统 | llm-wiki graph-engine 构建（一次性 `npm run build -w @llm-wiki/graph-engine`） |

## 安装

```bash
# 1. 克隆本仓库到 pi 的 skills 目录
git clone https://github.com/getfunWindz/bilibili-to-wiki.git ~/.pi/agent/skills/bilibili-to-wiki

# 2. 确保两个依赖 skill 已安装（见上方「依赖」表）

# 3. 确保知识库已初始化（~/.llm-wiki-path 存在）
cat ~/.llm-wiki-path   # 应输出知识库路径，如 C:\Users\xxx\llm-wiki-kb
```

## 使用方法

在 pi（或任何 Agent Skills 兼容的 CLI）中说：

```
「把 BV1RkFAznESD 加进知识库」
「消化这个 B 站视频」
「把这个视频入库：<链接>」
```

### 编排流程（SKILL.md 工作流 A 主线）

1. `ingest-pipeline.sh <视频>` → bilibili-learn 抓取字幕 + glossary 勘误（输出 corrected 稿）
2. agent 复制 corrected 稿到 `$KB/raw/notes/<日期>-<标题>.md`（含 front matter）
3. `cache.sh check` → **MISS**：走 ingest（Step1 JSON → validate → source/entity/topic 页 → index/log）｜ **HIT**：直接复用，零 LLM 调用
4. `glossary.py absorb $KB/wiki` 反哺新术语
5. `build-graph-data.sh` + `build-graph-html.sh` 重建图谱

### 两种使用形态

| 形态 | 触发 | 说明 |
|------|------|------|
| **全新流程** | 素材第一次 digest | 完整链路（抓取→勘误→入库→消化→反哺→图谱） |
| **复用流程** | 素材已 digest 过 | cache HIT 短路，秒级跳过，零 LLM 调用 |

## Glossary 双向闭环设计

```
表 → 库（正用）：ingest 前 glossary.py clean——替换已知勘误，未命中走 LLM/人工判断
                    ▲                    │
           （echo 回填 correct）   （新术语/新勘误）
                    │                    ▼
库 → 表（反哺）：digest 后 glossary.py absorb——实体页/主题页新概念沉淀回术语表
```

`glossary.json` 扩展结构（向后兼容，旧术语条目不变）：

```json
{
  "Anthropic": "AI 公司…",
  "_aliases": {
    "ATHROPIC": {"correct": "Anthropic", "type": "stt_error"},
    "easy deset": {"correct": "Easy Dataset", "type": "stt_error"}
  }
}
```

`type` 取值：`stt_error`（语音/字幕识别错误）｜ `naming`（译名/别名统一）｜ `uncertain`（存疑，correct=null）

### glossary.py 命令

```
list                             列出术语库
add <术语> <解释>                沉淀术语（已有不覆盖）
check <报告.md> <subtitle.txt>   注释/覆盖校验
alias <错误> <标准>              登记勘误
aliases                          列出勘误映射
clean <文件> [--out <dst>]       按勘误映射替换（存疑项仅收集不替换）
absorb <wiki目录> [--dry]        反哺：扫描实体/主题页沉淀新术语
```

## 已知实践（2026-09-01 实测）

- **勘误示例**：`ATHROPIC→Anthropic`、`grab→grep`、`AH 的目录→agent 的目录`、`easy deset→Easy Dataset`（经 B 站搜索链验证：同一 UP 主 code秘密花园 有《Easy Dataset 最新更新解读》BV1Rq1hBtEJa）
- **复用验证**：cache HIT 短路生效——重跑同素材秒级跳过，wiki 页面零重复
- **易错点**：桥接脚本**不要自己猜文件名**（曾出现 slug 截断为 `RA.md` 的 bug，已改为 agent 命名）；`--no-whisper` 空参数会破坏参数解析（已修）

## 相关链接

- [bilibili-learn](https://github.com/sdyckjq-lab/llm-wiki-skill)（参考：llm-wiki skill，Karpathy 方法论）｜ bilibili-learn：B 站学习视频 skill（本仓库作者的本地开发项目）
- Karpathy 方法论：[llm-wiki gist](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)

## 许可证

MIT
