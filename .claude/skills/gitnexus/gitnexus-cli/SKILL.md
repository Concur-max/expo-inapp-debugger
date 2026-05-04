---
name: gitnexus-cli
description: "当需要运行 GitNexus CLI 时使用：索引仓库、查看状态、清理索引、生成 wiki、列出仓库。"
---

# GitNexus CLI 命令

所有命令都可以用 `npx` 运行，不需要全局安装。

## 常用命令

### 建立或刷新索引

```bash
npx gitnexus analyze
```

在项目根目录运行。它会解析源码，建立知识图谱，写入 `.gitnexus/`，并生成 `AGENTS.md` / `CLAUDE.md`。

常用参数：

| 参数 | 作用 |
| --- | --- |
| `--force` | 强制全量重建索引 |
| `--skills` | 按图谱聚类生成 `.claude/skills/generated/` |
| `--skip-agents-md` | 不更新 `AGENTS.md` 和 `CLAUDE.md` |
| `--no-stats` | 不写入容易变化的统计数字 |
| `--name <alias>` | 给仓库注册别名 |
| `--embeddings` | 生成语义搜索向量，默认关闭 |

本仓库中文说明已经人工改过。刷新图谱但保留中文说明时建议用：

```bash
npx gitnexus analyze --force --skip-agents-md
```

### 查看索引状态

```bash
npx gitnexus status
```

显示当前仓库是否已索引、索引时间、提交号、文件/符号/关系数量。

### 列出所有索引仓库

```bash
npx gitnexus list
```

读取 `~/.gitnexus/registry.json`，列出 GitNexus 已注册的仓库。

### 删除当前仓库索引

```bash
npx gitnexus clean --force
```

删除 `.gitnexus/` 并从 registry 取消注册。索引损坏或需要彻底重建时使用。

### 删除指定仓库索引

```bash
npx gitnexus remove --force <name-or-path>
```

可以按别名、仓库名或绝对路径删除。

### 生成 wiki

```bash
npx gitnexus wiki
```

根据图谱调用 LLM 生成仓库文档，需要 API key。当前 CLI help 没有 `--language` 参数；要中文 wiki 通常需要后处理翻译，或修改/包装 GitNexus 的 prompt。

## 当前仓库状态

```bash
npx gitnexus status
```

当前已索引仓库别名：`expo-inapp-debugger`。

图谱位置：

- `.gitnexus/lbug`
- `.gitnexus/meta.json`

AI 阅读入口：

- `AGENTS.md`
- `CLAUDE.md`
- `.claude/skills/generated/`
- `.claude/skills/gitnexus/`
