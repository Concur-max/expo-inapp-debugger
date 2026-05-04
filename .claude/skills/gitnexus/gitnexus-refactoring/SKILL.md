---
name: gitnexus-refactoring
description: "重构前使用 GitNexus：评估依赖、调用链、执行流程和重命名风险。"
---

# 用 GitNexus 辅助重构

## 适用场景

- 重命名函数、类、方法或导出 API。
- 拆分 `DebugRuntime`、网络采集器、native Store、面板 UI。
- 移动文件或调整模块边界。
- 提取公共模型、排序逻辑、序列化逻辑。

## 基本流程

1. 用 `context` 看目标符号的上下游。
2. 用 `impact` 看影响面和风险等级。
3. 如果风险高，先写下受影响模块和测试点。
4. 小步修改。
5. 跑测试和 `detect-changes`。

## 常用命令

```bash
npx gitnexus context <symbol>
npx gitnexus impact <symbol>
npx gitnexus detect-changes
```

## 本仓库重构重点

| 区域 | 风险点 |
| --- | --- |
| `src/internal/runtime.ts` | 采集器安装、flush、native module 写入、Provider 控制权 |
| `src/internal/network.ts` | fetch/XHR/WebSocket hook、preview、时间线排序 |
| `src/index.ts` | 懒加载导出，影响关闭态开销 |
| Android Store/Panel | UI 展示、过滤、排序、native 数据结构 |
| iOS Store/Panel | UIKit 生命周期、URLProtocol、WebSocket、OSLog |

## 注意

- 不要只用文本替换做重命名，先用图谱确认调用方和导入方。
- 改公共类型或导出入口时，优先跑 `pnpm test` 和 `pnpm typecheck`。
- Android/iOS 同名概念很多，查 `context` 时如果返回 ambiguous，要按文件路径选择。
