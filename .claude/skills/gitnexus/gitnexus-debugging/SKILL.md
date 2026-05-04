---
name: gitnexus-debugging
description: "排查 bug 时使用 GitNexus：从症状定位执行流、符号上下游和可能破坏点。"
---

# 用 GitNexus 调试问题

## 适用场景

- 日志没有进入面板。
- 网络请求没有显示或时间线顺序不对。
- Provider 启停行为异常。
- Android/iOS 原生面板、浮动按钮或采集器异常。
- Error Boundary 或全局异常捕获不符合预期。

## 推荐流程

1. 先用 `status` 确认图谱是最新的。
2. 根据症状找模块 skill。
3. 用 `context` 查核心符号上下游。
4. 用 `impact` 判断改动风险。
5. 回到代码和测试验证。

## 常用入口

```bash
npx gitnexus context DebugRuntime
npx gitnexus context NetworkCollector
npx gitnexus context InAppDebugProvider
npx gitnexus context InAppDebuggerStore
npx gitnexus context InAppDebuggerPanelViewController
```

## 症状到模块

| 症状 | 先看 |
| --- | --- |
| JS console/error/promise 捕获问题 | `.claude/skills/generated/internal/SKILL.md` |
| fetch/XHR/WebSocket 捕获问题 | `.claude/skills/generated/internal/SKILL.md` |
| Android 面板或 native log/network 问题 | `.claude/skills/generated/inappdebugger/SKILL.md` |
| iOS 面板或 native log/network 问题 | `.claude/skills/generated/ios/SKILL.md` |
| 示例 App 触发链路问题 | `.claude/skills/generated/example/SKILL.md` |

## 调试建议

- 先查“写入点”和“展示点”之间的链路，例如 runtime 入队、flush、native store、panel render。
- Android/iOS 问题要同时看 native Store 和面板 Controller/Fragment。
- 网络问题要区分 JS fetch/XHR/WebSocket 和 native URLSession/OkHttp/WebSocket。
