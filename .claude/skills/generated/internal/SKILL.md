---
name: internal
description: "用于理解和修改 expo-inapp-debugger 的 JS 内部 runtime 区域。86 个符号，9 个文件。"
---

# Internal 区域

86 个符号 | 9 个文件 | 内聚度 73%

## 什么时候看这里

- 修改 `src/` 下的 JS/TypeScript runtime。
- 理解 `InAppDebugProvider` 如何创建、启停、配置 `DebugRuntime`。
- 理解 console/error/promise/network 采集、flush、native module 写入。
- 追踪 `formatMessage`、`materializeNetworkEntry`、`resolveStrings`、`enableDebugRuntime` 等符号。

## 关键文件

| 文件 | 主要符号 |
| --- | --- |
| `src/internal/runtime.ts` | `DebugRuntime`、日志/错误/网络入队、collector 安装与卸载 |
| `src/internal/network.ts` | fetch/XHR/WebSocket 采集、network entry 归一化 |
| `src/internal/singleton.ts` | runtime 单例、Provider 注册、兼容 Controller API |
| `src/internal/config.ts` | Provider 配置解析、Android native logs 配置 |
| `src/internal/strings.ts` | 中英文文案、locale 解析 |
| `src/InAppDebugProvider.tsx` | React Provider 生命周期和启停开关 |
| `src/inAppDebug.ts` | 手动日志与错误捕获的轻量入口 |
| `__tests__/runtime.test.ts` | runtime 行为测试 |

## 推荐入口

| 符号 | 类型 | 位置 |
| --- | --- | --- |
| `DebugRuntime` | Class | `src/internal/runtime.ts:160` |
| `NetworkCollector` | Class | `src/internal/network.ts:147` |
| `formatMessage` | Function | `src/internal/runtime.ts:115` |
| `materializeNetworkEntry` | Function | `src/internal/network.ts:472` |
| `resolveStrings` | Function | `src/internal/strings.ts:196` |
| `enableDebugRuntime` | Function | `src/internal/singleton.ts:49` |
| `disableDebugRuntime` | Function | `src/internal/singleton.ts:62` |
| `resolveProviderConfig` | Function | `src/internal/config.ts:63` |
| `InAppDebugProvider` | Function | `src/InAppDebugProvider.tsx:6` |

## 常见执行流

| 流程 | 含义 |
| --- | --- |
| `InAppDebugProvider -> DebugRuntime` | Provider 创建/注册 runtime 的核心路径 |
| `Constructor -> MaterializeNetworkEntry` | runtime 构造后连接网络条目归一化 |
| `CaptureConsoleError -> ResolveTimelineSequence` | console error 写入时间线 |
| `ApplyPanelRootEnhancedMode -> ReleaseXHRRequest` | 面板配置影响 XHR 采集释放 |
| `Shutdown -> ResolveTimelineSequence` | runtime 关闭时清理时间线相关状态 |

## 连接区域

- `Example`：示例 App 使用 Provider 和 API 触发采集。
- `Inappdebugger`：JS runtime 最终通过 native module 推送到 Android/iOS 面板。

## 怎么继续查

```bash
npx gitnexus context DebugRuntime
npx gitnexus impact DebugRuntime
npx gitnexus context materializeNetworkEntry
```
