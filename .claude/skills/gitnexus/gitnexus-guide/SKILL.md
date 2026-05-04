---
name: gitnexus-guide
description: "GitNexus 资源、查询方式和本仓库图谱结构速查。"
---

# GitNexus 速查

## 图谱文件

| 路径 | 说明 |
| --- | --- |
| `.gitnexus/lbug` | 本地图数据库 |
| `.gitnexus/meta.json` | 索引元数据 |
| `.gitnexusignore` | 索引范围控制 |

## AI 文档

| 路径 | 说明 |
| --- | --- |
| `AGENTS.md` | Codex/Cursor/Windsurf/OpenCode 等 agent 的项目入口 |
| `CLAUDE.md` | Claude Code 的项目入口 |
| `.claude/skills/generated/` | 按图谱聚类生成的模块指南 |
| `.claude/skills/gitnexus/` | GitNexus 操作指南 |

## 常用 CLI

```bash
npx gitnexus status
npx gitnexus list
npx gitnexus context <symbol>
npx gitnexus impact <symbol>
npx gitnexus cypher "<query>"
```

## 常用 Cypher 例子

```bash
npx gitnexus cypher "MATCH (n) RETURN labels(n) AS labels, count(n) AS count ORDER BY count DESC"
```

```bash
npx gitnexus cypher "MATCH (f:File) RETURN f.name AS file ORDER BY file"
```

## 当前图谱统计

- 文件：58
- 节点：3,496
- 关系：8,954
- 功能聚类：179
- 执行流程：300

## 重要限制

- `AGENTS.md`、`CLAUDE.md`、skill 文件是 Markdown 说明，不是图数据库本体。
- `.gitnexus/lbug` 才是 GitNexus 的机器读知识图谱。
- GitNexus 1.6.3 的 `analyze --skills` 默认英文，没有中文参数；本仓库这些说明已人工中文化。
