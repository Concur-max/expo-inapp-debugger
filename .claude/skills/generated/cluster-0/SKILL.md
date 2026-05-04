---
name: cluster-0
description: "用于理解 src/index.ts 中 Provider、Boundary、Root 的懒加载导出。6 个符号，1 个文件。"
---

# Cluster_0 区域

6 个符号 | 1 个文件 | 内聚度 100%

## 什么时候看这里

- 修改包入口 `src/index.ts`。
- 理解为什么入口文件使用懒加载，避免 import 包时立刻求值全部 runtime。
- 调整 `InAppDebugProvider`、`InAppDebugBoundary`、`InAppDebugRoot` 的导出行为。

## 关键文件

| 文件 | 主要符号 |
| --- | --- |
| `src/index.ts` | `loadReact`、`loadInAppDebugProvider`、`loadInAppDebugBoundary`、`InAppDebugProvider`、`InAppDebugBoundary`、`InAppDebugRoot` |

## 推荐入口

| 符号 | 类型 | 位置 |
| --- | --- | --- |
| `loadReact` | Function | `src/index.ts:34` |
| `loadInAppDebugProvider` | Function | `src/index.ts:41` |
| `loadInAppDebugBoundary` | Function | `src/index.ts:48` |
| `InAppDebugProvider` | Function | `src/index.ts:69` |
| `InAppDebugBoundary` | Function | `src/index.ts:75` |
| `InAppDebugRoot` | Function | `src/index.ts:81` |

## 怎么继续查

```bash
npx gitnexus context loadReact
npx gitnexus impact InAppDebugRoot
```
