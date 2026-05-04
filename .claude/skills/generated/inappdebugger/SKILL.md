---
name: inappdebugger
description: "用于理解和修改 expo-inapp-debugger 的 Android 原生调试器区域。421 个符号，11 个文件。"
---

# Inappdebugger 区域

421 个符号 | 11 个文件 | 内聚度 75%

## 什么时候看这里

- 修改 `android/` 下的原生调试器代码。
- 理解 Android 浮动按钮、调试面板、日志采集、网络采集、Store 数据流。
- 追踪 `toMap`、`formatNativeLogClock`、`createNativeDebugLogEntry`、`timelineSortKey` 等符号。

## 关键文件

| 文件 | 主要符号 |
| --- | --- |
| `android/src/main/java/expo/modules/inappdebugger/InAppDebuggerPanelDialogFragment.kt` | 面板 UI、筛选、详情页、App Info 渲染 |
| `android/src/main/java/expo/modules/inappdebugger/InAppDebuggerNativeNetworkCapture.kt` | OkHttp/网络事件采集、HTTP/WebSocket 条目生成 |
| `android/src/main/java/expo/modules/inappdebugger/InAppDebuggerStore.kt` | 日志、错误、网络请求的内存 Store 和 snapshot |
| `android/src/main/java/expo/modules/inappdebugger/InAppDebuggerNativeLogCapture.kt` | logcat/stdout/stderr/异常采集和 runtime 状态 |
| `android/src/main/java/expo/modules/inappdebugger/InAppDebuggerModels.kt` | Android 侧数据模型、时间线排序、Map 序列化 |
| `android/src/main/java/expo/modules/inappdebugger/InAppDebuggerOverlayManager.kt` | 浮动入口显示/隐藏、Activity 生命周期 |
| `android/src/main/java/expo/modules/inappdebugger/InAppDebuggerFloatingButtonView.kt` | 可拖动浮动按钮 |
| `android/src/main/java/expo/modules/inappdebugger/InAppDebuggerModule.kt` | Expo Module 原生桥定义 |
| `src/internal/network.ts` | JS 网络采集和 Android native 网络时间线的共享逻辑 |
| `ios/InAppDebuggerOverlayManager.swift` | 图谱中与浮动按钮相关的跨平台连接 |

## 推荐入口

| 符号 | 类型 | 位置 |
| --- | --- | --- |
| `toMap` | Function | `android/src/main/java/expo/modules/inappdebugger/InAppDebuggerModels.kt:290` |
| `formatNativeLogClock` | Function | `android/src/main/java/expo/modules/inappdebugger/InAppDebuggerModels.kt:164` |
| `createNativeDebugLogEntry` | Function | `android/src/main/java/expo/modules/inappdebugger/InAppDebuggerModels.kt:198` |
| `timelineSortKey` | Function | `android/src/main/java/expo/modules/inappdebugger/InAppDebuggerModels.kt:221` |
| `updateConfig` | Method | `android/src/main/java/expo/modules/inappdebugger/InAppDebuggerStore.kt:45` |
| `ingestBatch` | Method | `android/src/main/java/expo/modules/inappdebugger/InAppDebuggerStore.kt:91` |
| `upsertNetworkEntry` | Method | `android/src/main/java/expo/modules/inappdebugger/InAppDebuggerStore.kt:244` |
| `InAppDebuggerPanelDialogFragment` | Class | `android/src/main/java/expo/modules/inappdebugger/InAppDebuggerPanelDialogFragment.kt:101` |

## 常见执行流

| 流程 | 含义 |
| --- | --- |
| `Definition -> EnsurePanelContainer` | Expo Module 定义触发面板容器准备 |
| `Definition -> InAppDebuggerPanelDialogFragment` | 原生模块入口连接 Android 面板 |
| `ApplyPanelRootEnhancedMode -> DebugRuntimeInfo` | 面板 root 配置影响 runtime 信息展示 |
| `Shutdown -> CompareNetworkTimeline` | 关闭流程影响网络时间线排序和清理 |
| `Definition -> DetachButton` | 原生模块生命周期连接浮动按钮移除 |

## 连接区域

- `Ios`：跨平台模型、浮动入口、网络/日志采集概念相互对应。
- `Example`：示例 App 会触发日志、HTTP、WebSocket 流程。
- `Internal`：JS runtime 通过 native module 写入 Android Store 和 UI。

## 怎么继续查

```bash
npx gitnexus context toMap
npx gitnexus context InAppDebuggerPanelDialogFragment
npx gitnexus impact InAppDebuggerStore
```
