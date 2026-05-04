---
name: cluster-2
description: "用于理解 src/index.ts 中 inAppDebug.log 和 captureError 的懒加载 API。3 个符号，1 个文件。"
---

# Cluster_2 区域

3 个符号 | 1 个文件 | 内聚度 100%

## 什么时候看这里

- 修改包入口里的 `inAppDebug` 对象。
- 理解 `log` / `captureError` 如何懒加载内部实现。
- 保持未启用或未创建 runtime 时的 no-op 行为。

## 关键文件

| 文件 | 主要符号 |
| --- | --- |
| `src/index.ts` | `loadInAppDebug`、`log`、`captureError` |

## 推荐入口

| 符号 | 类型 | 位置 |
| --- | --- | --- |
| `loadInAppDebug` | Function | `src/index.ts:62` |
| `log` | Method | `src/index.ts:124` |
| `captureError` | Method | `src/index.ts:127` |

## 怎么继续查

```bash
npx gitnexus context loadInAppDebug
npx gitnexus impact captureError
```
