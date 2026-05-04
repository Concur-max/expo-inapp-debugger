<!-- gitnexus:start -->
# GitNexus 代码知识图谱

这个项目已经用 GitNexus 建立索引，仓库别名是 **expo-inapp-debugger**。

当前图谱规模：

- 58 个文件
- 3,496 个节点
- 8,954 条关系
- 179 个功能聚类
- 300 条执行流程

## 图谱在哪里

| 路径 | 作用 |
| --- | --- |
| `.gitnexus/lbug` | GitNexus 的本地图数据库，主要给 GitNexus/MCP/CLI 读取 |
| `.gitnexus/meta.json` | 本次索引的仓库路径、提交、统计信息 |
| `.claude/skills/generated/` | GitNexus 按模块生成的 AI 阅读指南 |
| `.claude/skills/gitnexus/` | GitNexus 查询、调试、影响分析、重构等操作指南 |
| `AGENTS.md` / `CLAUDE.md` | 给 AI agent 启动时读取的项目上下文 |
| `.gitnexusignore` | 控制哪些文件进入图谱 |

`.gitnexus/` 是机器读的图数据库，不适合直接手读；人和 AI 通常先读本文件和 `.claude/skills/.../SKILL.md`，需要精确关系时再调用 GitNexus CLI/MCP。

## 使用原则

- 修改任何函数、类、方法前，先跑影响分析：`npx gitnexus impact <symbol>`
- 如果影响分析返回 HIGH 或 CRITICAL，先把风险说明清楚再动代码。
- 不熟悉某块代码时，优先看对应的 skill 文件，再用 `context` 看符号上下游。
- 提交前建议跑 `npx gitnexus detect-changes`，确认变更影响范围符合预期。
- 如果 GitNexus 提示索引过期，运行 `npx gitnexus analyze --force --skip-agents-md` 刷新图谱。

## 常用命令

| 任务 | 命令 |
| --- | --- |
| 查看索引状态 | `npx gitnexus status` |
| 列出已索引仓库 | `npx gitnexus list` |
| 查看符号上下文 | `npx gitnexus context <symbol>` |
| 查看修改影响面 | `npx gitnexus impact <symbol>` |
| 执行 Cypher 查询 | `npx gitnexus cypher "<query>"` |
| 重新索引但保留中文说明 | `npx gitnexus analyze --force --skip-agents-md` |
| 删除并重建索引 | `npx gitnexus clean --force && npx gitnexus analyze --force --skip-agents-md` |

## 模块入口

| 场景 | 阅读文件 |
| --- | --- |
| 理解 Android 原生调试器、面板、网络/日志采集 | `.claude/skills/generated/inappdebugger/SKILL.md` |
| 理解 iOS 原生调试器、面板、网络/日志采集 | `.claude/skills/generated/ios/SKILL.md` |
| 理解 JS runtime、Provider、网络拦截、单例生命周期 | `.claude/skills/generated/internal/SKILL.md` |
| 理解 example 应用和测试入口 | `.claude/skills/generated/example/SKILL.md` |
| 理解 `src/index.ts` 懒加载导出 | `.claude/skills/generated/cluster-0/SKILL.md` |
| 理解 `inAppDebug.log/captureError` 懒加载 API | `.claude/skills/generated/cluster-2/SKILL.md` |

## GitNexus 操作指南

| 任务 | 阅读文件 |
| --- | --- |
| 了解 GitNexus CLI | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |
| 探索架构和执行流程 | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| 调试问题 | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| 做影响分析 | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| 做重构 | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| 查看资源和查询语法 | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |

## 中文说明

这些文件最初由 `npx gitnexus analyze --skills` 生成。GitNexus 1.6.3 的 `analyze --skills` 没有语言参数，默认模板是英文；本仓库里的说明已经改成中文。

注意：以后如果重新运行 `npx gitnexus analyze --skills`，GitNexus 可能会把这些中文说明覆盖回英文。只想刷新图谱时，建议用：

```bash
npx gitnexus analyze --force --skip-agents-md
```

<!-- gitnexus:end -->
