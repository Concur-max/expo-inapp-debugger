---
name: gitnexus-exploring
description: "当需要理解架构、执行流程、模块关系或某个概念如何实现时使用 GitNexus。"
---

# 用 GitNexus 探索代码

## 适用场景

- “这个功能怎么跑起来的？”
- “某个符号在哪里定义、谁调用它、它又调用谁？”
- “这个模块和别的模块有什么关系？”
- “我准备改代码，先想知道相关流程。”

## 推荐步骤

1. 先看 `AGENTS.md` 或 `CLAUDE.md`，确认图谱规模和模块入口。
2. 根据目录选择 `.claude/skills/generated/.../SKILL.md`。
3. 用 `context` 查精确符号上下文。
4. 用 `cypher` 查图谱结构。
5. 修改前用 `impact` 看影响面。

## 常用命令

```bash
npx gitnexus status
npx gitnexus context DebugRuntime
npx gitnexus context InAppDebuggerPanelViewController
npx gitnexus impact DebugRuntime
```

## 查询建议

- 查 JS runtime：先看 `.claude/skills/generated/internal/SKILL.md`
- 查 Android：先看 `.claude/skills/generated/inappdebugger/SKILL.md`
- 查 iOS：先看 `.claude/skills/generated/ios/SKILL.md`
- 查示例：先看 `.claude/skills/generated/example/SKILL.md`

## 注意

`context` 和 `impact` 对精确符号最可靠。自然语言 `query` 在当前 GitNexus 1.6.3 环境里可能受 FTS/embeddings 状态影响，不如 `context`、`impact`、`cypher` 稳定。
