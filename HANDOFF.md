# expo-inapp-debugger Handoff

最后更新：2026-04-06 17:40，Asia/Shanghai。

这份文档用于新对话快速接手 `/Users/xingyuyang/Projects/expo-inapp-debugger`。

## 当前目标

做一个可发布到 npm 的独立原生调试工具包，给 Expo / React Native dev build 或 bare RN 使用。不支持 Expo Go。

核心方向：

- JS 侧只提供轻量 runtime shim，在 `enabled=true` 时采集 `console`、全局错误、Promise rejection、React ErrorBoundary、JS 发起的 `fetch` / `XMLHttpRequest` / `WebSocket`。
- iOS UI 使用 Swift + UIKit，全原生覆盖层。
- Android UI 使用 Kotlin + Jetpack Compose，全原生覆盖层。
- 默认语言是中文，技术名词如 `Console`、`Network`、`React` 可以保留英文。
- Release 默认休眠，只有调用方显式 `enabled=true` 才显示 UI 和安装采集逻辑。

## 重要路径

- 包根目录：`/Users/xingyuyang/Projects/expo-inapp-debugger`
- Example：`/Users/xingyuyang/Projects/expo-inapp-debugger/example`
- JS API：`src/index.ts`
- Provider：`src/InAppDebugProvider.tsx`
- ErrorBoundary：`src/InAppDebugBoundary.tsx`
- Controller：`src/InAppDebugController.ts`
- Runtime shim：`src/internal/runtime.ts`
- Network shim：`src/internal/network.ts`
- 文案：`src/internal/strings.ts`
- iOS module：`ios/InAppDebuggerModule.swift`
- iOS store：`ios/InAppDebuggerStore.swift`
- iOS overlay：`ios/InAppDebuggerOverlayManager.swift`
- iOS panel：`ios/InAppDebuggerPanelViewController.swift`
- Android module：`android/src/main/java/expo/modules/inappdebugger/InAppDebuggerModule.kt`
- Android panel：`android/src/main/java/expo/modules/inappdebugger/InAppDebuggerPanelDialogFragment.kt`
- Expo module config：`expo-module.config.json`

## 已修过的关键坑

- `pnpm + expo/AppEntry.js` 会把 `../../App` 解析到 `.pnpm` 真实路径，example 已改成 `main: "index.js"` 和本地 `index.js`。
- 默认语言已切到 `zh-CN`。
- `InAppDebugBoundary` 里不能用 TS `declare context`，Metro/Babel 编译 node_modules TSX 会报错；已移除。
- `console` patch 不能保存 `console` 对象引用，否则 patch 后 `console.info` 会递归到自己并栈溢出；`src/internal/runtime.ts` 现在保存的是绑定后的原始方法副本。
- Expo SDK 54 的 module config 要用 `"platforms": ["apple", "android"]` 和 `"apple": { "modules": [...] }`，不是旧的 `"ios"`。
- iOS 最低版本必须和 podspec 一致：`InAppDebugger.podspec` 是 iOS 15.5，example 也已通过 `expo-build-properties` 和 Xcode project 设为 15.5。
- iOS 面板一开始能显示但所有按钮无响应，是 `PassThroughWindow` 只允许悬浮按钮 hit-test。现在逻辑是：未打开面板时 pass-through，面板 presented 后全屏 debug window 接收触摸。
- `InAppDebuggerPanelViewController.swift` 的网络详情数组表达式曾触发 Swift type-check 超时，已拆成显式中间变量和带类型的 sections 数组。
- example 加了 `expo-build-properties`，配置了 `ios.deploymentTarget=15.5` 和 `android.minSdkVersion=24`，防止 `prebuild --clean` 后回退。

## 当前已验证状态

已验证通过：

```bash
cd /Users/xingyuyang/Projects/expo-inapp-debugger
pnpm exec tsc -p tsconfig.json --noEmit
pnpm exec jest --runInBand
```

```bash
cd /Users/xingyuyang/Projects/expo-inapp-debugger/example
pnpm exec tsc -p tsconfig.json --noEmit
```

已验证 iOS 真机 Debug build 通过：

```bash
cd /Users/xingyuyang/Projects/expo-inapp-debugger/example
xcodebuild -workspace ios/ExpoInAppDebuggerExample.xcworkspace -scheme ExpoInAppDebuggerExample -configuration Debug -destination id=00008120-000E3D32263B401E build
```

最后一次结果是 `BUILD SUCCEEDED`，并且已经安装到真机，bundle id：

```text
com.example.expoinappdebugger
```

用户确认：悬浮调试器能显示，调试面板打开后触摸也已恢复可用。

## 运行方式

真机 LAN Metro 推荐：

```bash
cd /Users/xingyuyang/Projects/expo-inapp-debugger/example
REACT_NATIVE_PACKAGER_HOSTNAME=192.168.21.207 pnpm start:lan:clear
```

如果 `192.168.21.207` 不通，之前机器上也出现过另一个可用局域网 IP：

```bash
REACT_NATIVE_PACKAGER_HOSTNAME=192.168.21.241 pnpm start:lan:clear
```

改 iOS 原生代码后：

```bash
cd /Users/xingyuyang/Projects/expo-inapp-debugger/example
npx expo run:ios --device
```

或者直接：

```bash
cd /Users/xingyuyang/Projects/expo-inapp-debugger/example
xcodebuild -workspace ios/ExpoInAppDebuggerExample.xcworkspace -scheme ExpoInAppDebuggerExample -configuration Debug -destination id=00008120-000E3D32263B401E build
xcrun devicectl device install app --device 00008120-000E3D32263B401E /Users/xingyuyang/Library/Developer/Xcode/DerivedData/ExpoInAppDebuggerExample-ekcpkhmlctkslucmgjpfprbuqwbl/Build/Products/Debug-iphoneos/ExpoInAppDebuggerExample.app
```

## 现阶段能力边界

- UI 已是原生覆盖层，但功能还只是首版形态，后面要“大干内容”时重点应放在体验、性能、交互细节和功能完整度。
- 网络面板只采集 JS 层 `fetch` / `XMLHttpRequest` / `WebSocket`，不保证拦截任意第三方原生 SDK 流量。
- 当前 example 的 iOS/Android 原生目录已生成；如果 `prebuild --clean`，需要重新确认 iOS scheme、deployment target、Android minSdk 和 autolinking。
- 根目录不是 git repo，注意不要用 git 命令作为唯一事实来源。

## 建议下一步任务

优先做这些：

- 完整梳理 iOS panel 的 UI/UX：搜索、筛选、排序、复制、清空、日志详情、网络详情、错误展示都要变得更好用。
- 增加 errors tab 或在 logs tab 内明确区分 errors，目前原生面板主要是 logs/network。
- 优化 native store：批量更新节流、可见列表 diff、搜索过滤性能、导出 snapshot 格式。
- 做 Android 真机跑通和 Compose 面板体验修复，iOS 已先跑通。
- 增强 example：增加明确的测试按钮、状态说明、中文文案、release idle 验证入口。
- 补 README：安装、Expo prebuild/dev build 接入、API 示例、限制说明、发布 npm 前检查。
- 补测试：runtime 已有 Jest 4 个测试，后续要覆盖 network shim、provider config、controller、ErrorBoundary、release idle。

## 给下个对话的启动提示

可以直接这样开场：

```text
请先阅读 /Users/xingyuyang/Projects/expo-inapp-debugger/HANDOFF.md，然后继续实现 expo-inapp-debugger 的下一阶段内容。优先从 iOS 原生调试面板体验和功能完整度开始，保持默认中文，技术名词可保留英文。改动后请跑 TypeScript/Jest，并尽量验证 iOS build。
```
