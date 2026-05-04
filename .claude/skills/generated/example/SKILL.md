---
name: example
description: "用于理解和修改 expo-inapp-debugger 的 example 示例应用区域。13 个符号，4 个文件。"
---

# Example 区域

13 个符号 | 4 个文件 | 内聚度 65%

## 什么时候看这里

- 修改 `example/` 示例 App。
- 验证日志、错误、HTTP、WebSocket、native log 等调试器能力。
- 看宿主 App 如何接入 `InAppDebugRoot` / `InAppDebugProvider`。

## 关键文件

| 文件 | 主要符号 |
| --- | --- |
| `example/App.tsx` | 示例 UI、HTTP/WS 触发按钮、日志/错误演示 |
| `example/scripts/http-mock-server.mjs` | 本地 HTTP mock server |
| `example/scripts/ws-echo-server.mjs` | 本地 WebSocket echo server |
| `example/package.json` | 示例 App 脚本和依赖 |

## 推荐入口

| 符号 | 类型 | 位置 |
| --- | --- | --- |
| `App` | Function | `example/App.tsx:128` |
| `createDemoSocketPayload` | Function | `example/App.tsx:85` |
| `createDemoPostPayload` | Function | `example/App.tsx:94` |
| `normalizeBaseUrl` | Function | `example/App.tsx:111` |
| `formatJSONText` | Function | `example/App.tsx:120` |
| `resolveDefaultWebSocketUrl` | Function | `example/App.tsx:63` |
| `resolveDefaultHttpBaseUrl` | Function | `example/App.tsx:74` |

## 常见执行流

| 流程 | 含义 |
| --- | --- |
| `ViewDidDisappear -> Close` | 原生面板消失时关闭相关资源 |
| `Shutdown -> Close` | 关闭调试器时清理连接 |
| `Definition -> Close` | 原生模块定义和 close 资源释放有关 |

## 怎么继续查

```bash
npx gitnexus context App
npx gitnexus impact App
```
