---
name: gitnexus-impact-analysis
description: "修改符号前评估影响面时使用：查看调用方、受影响流程、风险等级。"
---

# GitNexus 影响分析

## 什么时候必须用

- 修改函数、类、方法、导出 API 前。
- 重命名、拆分、移动代码前。
- 改 native module、runtime、Provider、网络/日志采集前。
- 准备提交前想确认影响范围。

## 命令

```bash
npx gitnexus impact <symbol>
```

例子：

```bash
npx gitnexus impact DebugRuntime
npx gitnexus impact InAppDebugProvider
npx gitnexus impact upsertNetworkEntry
```

## 怎么读结果

| 字段 | 含义 |
| --- | --- |
| `risk` | GitNexus 给出的风险等级 |
| `impactedCount` | 受影响节点数量 |
| `summary.direct` | 直接依赖方数量 |
| `affected_processes` | 可能受影响的执行流程 |
| `byDepth` | 按依赖深度展开的影响链 |

## 处理规则

- LOW：通常可以继续，但仍要跑测试。
- MEDIUM：说明影响面，优先补测试。
- HIGH / CRITICAL：先停一下，把风险告诉用户，再决定是否继续。

## 本仓库常见高价值符号

```bash
npx gitnexus impact DebugRuntime
npx gitnexus impact NetworkCollector
npx gitnexus impact InAppDebugProvider
npx gitnexus impact InAppDebuggerStore
npx gitnexus impact InAppDebuggerPanelViewController
```

## 提交前

```bash
npx gitnexus detect-changes
```

用于把 git diff 映射到被修改符号和受影响执行流。
