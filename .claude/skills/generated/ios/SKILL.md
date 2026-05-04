---
name: ios
description: "用于理解和修改 expo-inapp-debugger 的 iOS 原生调试器区域。401 个符号，10 个文件。"
---

# iOS 区域

401 个符号 | 10 个文件 | 内聚度 74%

## 什么时候看这里

- 修改 `ios/` 下的 Swift 原生调试器代码。
- 理解 iOS 浮动按钮、调试面板、日志采集、URLSession/WebSocket 采集和 Store。
- 追踪 `upsertNetworkEntry`、`appendResponsePreview`、`materializeResponseBody`、`urlSession` 等符号。

## 关键文件

| 文件 | 主要符号 |
| --- | --- |
| `ios/InAppDebuggerPanelViewController.swift` | iOS 调试面板 UI、日志/网络列表、详情页、筛选搜索 |
| `ios/InAppDebuggerNativeLogCapture.swift` | stdout/stderr/OSLog/crash/signal/WebSocket 日志采集 |
| `ios/InAppDebuggerNativeNetworkCapture.swift` | URLProtocol、URLSession、WebSocket 网络采集 |
| `ios/InAppDebuggerStore.swift` | 日志、错误、网络请求、App Info 的 Store 和 snapshot |
| `ios/InAppDebuggerOverlayManager.swift` | 浮动按钮、窗口、面板展示和场景生命周期 |
| `ios/InAppDebuggerModels.swift` | iOS 侧模型、字典转换、时间线数据 |
| `ios/InAppDebuggerModule.swift` | Expo Module 原生桥定义 |
| `ios/InAppDebugger.podspec` | CocoaPods 集成配置 |

## 推荐入口

| 符号 | 类型 | 位置 |
| --- | --- | --- |
| `upsertNetworkEntry` | Function | `ios/InAppDebuggerStore.swift:314` |
| `appendResponsePreview` | Function | `ios/InAppDebuggerNativeNetworkCapture.swift:98` |
| `materializeResponseBody` | Function | `ios/InAppDebuggerNativeNetworkCapture.swift:107` |
| `asEntry` | Function | `ios/InAppDebuggerNativeNetworkCapture.swift:115` |
| `urlSession` | Function | `ios/InAppDebuggerNativeNetworkCapture.swift:295` |
| `InAppDebuggerPanelViewController` | Class | `ios/InAppDebuggerPanelViewController.swift:341` |
| `InAppDebuggerNativeURLSessionWebSocketState` | Class | `ios/InAppDebuggerNativeNetworkCapture.swift:141` |
| `PassThroughWindow` | Class | `ios/InAppDebuggerOverlayManager.swift:2` |

## 常见执行流

| 流程 | 含义 |
| --- | --- |
| `RenderFromSnapshotState -> StopLifecycleObserversLocked` | 面板渲染和生命周期观察清理有关 |
| `SearchTextChanged -> IsNativeOrigin` | 搜索筛选会影响 native 来源展示 |
| `SearchTextChanged -> IndexPaths` | 搜索输入驱动列表局部更新 |
| `SplitMessageMetadataAndPayload -> Advance` | native 日志解析和 token 游标推进 |
| `SplitMessageMetadataAndPayload -> IsDisallowedStringCharacter` | 日志 payload 安全解析 |

## 连接区域

- `Inappdebugger`：Android 与 iOS 的 native 面板、网络、日志能力相互对应。
- `Example`：示例 App 触发 iOS 网络和日志采集路径。

## 怎么继续查

```bash
npx gitnexus context upsertNetworkEntry
npx gitnexus context InAppDebuggerPanelViewController
npx gitnexus impact InAppDebuggerNativeNetworkCapture
```
