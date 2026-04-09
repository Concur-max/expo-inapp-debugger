# expo-inapp-debugger Handoff

最后更新：2026-04-09，Asia/Shanghai。

这份文档用于新对话快速接手 `/Users/fiee/Projects/expo-inapp-debugger`。

## 当前判断

当前上下文已经明显变大，继续在同一会话里做“持续精准采集前提下的极致性能优化”，边际效率会下降。建议直接开新会话，让下一个对话先读这份文档再继续实现。

## 当前目标

做一个可发布到 npm 的独立原生调试工具包，给 Expo / React Native dev build 或 bare RN 使用，不支持 Expo Go。

当前最重要的新目标已经收敛为：

- 在 `enabled=true` 时持续、尽量完整地采集调试信息，尽量不要因为“只在面板打开时采集”而错失关键现场。
- 在“持续采集”不退让的前提下，把性能开销压到尽可能低。
- 优先做 Android 的采集架构和 store/UI 更新链路优化；语言可以是 Kotlin / C++ / Rust / C，只要收益明确。

## 重要路径

- 包根目录：`/Users/fiee/Projects/expo-inapp-debugger`
- Example：`/Users/fiee/Projects/expo-inapp-debugger/example`
- JS runtime：`/Users/fiee/Projects/expo-inapp-debugger/src/internal/runtime.ts`
- JS network shim：`/Users/fiee/Projects/expo-inapp-debugger/src/internal/network.ts`
- Android store：`/Users/fiee/Projects/expo-inapp-debugger/android/src/main/java/expo/modules/inappdebugger/InAppDebuggerStore.kt`
- Android native capture：`/Users/fiee/Projects/expo-inapp-debugger/android/src/main/java/expo/modules/inappdebugger/InAppDebuggerNativeLogCapture.kt`
- Android panel：`/Users/fiee/Projects/expo-inapp-debugger/android/src/main/java/expo/modules/inappdebugger/InAppDebuggerPanelDialogFragment.kt`
- Android models：`/Users/fiee/Projects/expo-inapp-debugger/android/src/main/java/expo/modules/inappdebugger/InAppDebuggerModels.kt`
- iOS store：`/Users/fiee/Projects/expo-inapp-debugger/ios/InAppDebuggerStore.swift`
- iOS native network capture：`/Users/fiee/Projects/expo-inapp-debugger/ios/InAppDebuggerNativeNetworkCapture.swift`
- 现有 handoff：`/Users/fiee/Projects/expo-inapp-debugger/HANDOFF.md`

## 本轮已完成

### 1. Android WebSocket 状态语义修正

文件：

- `src/internal/network.ts`
- `__tests__/network.test.ts`

已做：

- Android / JS WebSocket 状态从 `success` 改成真正的生命周期语义：
  - `connect -> connecting`
  - `onOpen -> open`
  - `close() -> closing`
  - `onClose -> closed`
  - `onError -> error`
- 区分了“请求关闭”和“真实关闭”：
  - `requestedCloseCode` / `requestedCloseReason`
  - `closeCode` / `closeReason`
- 新增单测覆盖 WebSocket lifecycle。

验证：

```bash
cd /Users/fiee/Projects/expo-inapp-debugger
pnpm exec jest --runInBand
pnpm exec tsc -p tsconfig.json --noEmit
```

### 2. Android 面板标题与搜索框微调

文件：

- `android/src/main/java/expo/modules/inappdebugger/InAppDebuggerPanelDialogFragment.kt`

已做：

- 顶部标题改成固定 `Debugging panel`
- Android logs/network 搜索框 placeholder 统一成 `Please enter`
- 搜索框高度压低到 `48.dp`

验证：

```bash
cd /Users/fiee/Projects/expo-inapp-debugger/example/android
./gradlew :app:compileDebugKotlin
```

### 3. Android App Info 新增 crash / fatal error 记录

文件：

- `android/src/main/java/expo/modules/inappdebugger/InAppDebuggerModels.kt`
- `android/src/main/java/expo/modules/inappdebugger/InAppDebuggerNativeLogCapture.kt`
- `android/src/main/java/expo/modules/inappdebugger/InAppDebuggerPanelDialogFragment.kt`

已做：

- 在 `DebugRuntimeInfo` 里新增 `crashRecords`
- 新增 `DebugCrashRecord`
- Android 原生未捕获异常会：
  - 继续写一次性 crash replay 文件
  - 同时写 crash history JSON
  - history 默认最多保留 `6` 条
- App Info 里新增两组 section：
  - `Crash Records`：原生未捕获异常历史，含时间、线程、异常类、消息、堆栈
  - `Fatal Error Records`：从 `state.errors` 聚合的 `global` / `react` / `[FATAL]` 错误记录

验证：

```bash
cd /Users/fiee/Projects/expo-inapp-debugger/example/android
./gradlew :app:compileDebugKotlin
```

## 当前工作区状态

当前 git 视角下：

- `HANDOFF.md` 目前显示为未跟踪文件
- 其余本轮提到的代码文件在当前工作树里没有额外 diff

这意味着：

- Android WebSocket / App Info crash records / 搜索框与标题调整这些变更，已经体现在当前代码状态里
- 但这份 handoff 自身还没有纳入 git 跟踪

注意：

- 开新会话时先以磁盘上的当前文件内容为准
- 根目录现在是 git repo，可以用 git 看 diff，但不要把 git 当唯一事实来源

## 当前最重要的性能判断

用户明确要求的是：

- 调试器本质上要“持续采集”
- 不能为了省性能而只在面板打开时才开始采集
- 在这个前提下继续极致优化

所以“关闭采集以换性能”不是可接受答案。

真正的优化方向应是：

- 保留持续采集
- 把热路径上的格式化、桥接、全量复制、UI 刷新成本挪走或延后

## 当前识别出的主要性能热点

### 1. Android store 目前是全量快照式更新

文件：

- `android/src/main/java/expo/modules/inappdebugger/InAppDebuggerStore.kt`

问题：

- 每次 `emit()` 都会创建新的 `DebugPanelState`
- 每次都会 `logs.toList()` / `errors.toList()` / `network.toList()`
- Compose 层通过 `collectAsStateWithLifecycle()` 吃整个 state
- 这会让高频采集下出现 O(n) 拷贝和 O(n) 重组

这是 Android 当前最大热点之一。

### 2. JS network 热路径上存在 eager stringify / eager join

文件：

- `src/internal/network.ts`

问题：

- `safeStringify()` 在 send / response / message 上直接做字符串化
- WebSocket 每条消息都在更新 `messagesList`
- 然后执行 `join('\n')` 重建完整 `messages`

如果消息很多，这条链会越来越贵。

### 3. JS -> native ingestion 仍然是高层对象桥接

文件：

- `src/internal/runtime.ts`
- `android/src/main/java/expo/modules/inappdebugger/InAppDebuggerStore.kt`

问题：

- 现在是 JS 侧构造对象
- 通过 Expo module 把 `List<Map<String, Any?>>` 送到原生
- 原生再 parse 回结构体

这条桥接路径对象分配很多，不适合“持续高频采集”。

### 4. Android 目前没有 iOS 那种“采集继续、可见更新节流”的分层

对比：

- iOS store 有 `liveUpdatesEnabled`
- iOS native network capture 有 `panelActive` 和 `visibleThrottled`
- Android 基本还是“采集事件一来就推 UI state”

这会让 Android 面板打开时更容易出现重算和卡顿。

## 推荐的下一阶段技术路线

优先级从高到低如下。

### P0：先做 Android 架构级优化，不要先急着上 C++ / Rust

目标：

- 继续全量采集
- 但 UI 不再跟着每条事件全量刷新

建议先落地：

1. `capture plane` 和 `UI plane` 解耦
2. 采集继续写入内存缓冲
3. 面板关闭时不做高频 UI state 更新
4. 面板打开时只按节流频率刷新“窗口数据”

### P1：把 Android store 改成 ring buffer + version/cursor

建议做法：

- `logs/errors/network` 不再每次 `toList()`
- 改成固定容量 ring buffer
- store 只暴露：
  - `version`
  - `size`
  - `tailWindow(start,count)` 或者 `snapshotWindow()`
- UI 只拿最近窗口，不拿全量历史

收益：

- 采集热路径几乎 O(1)
- 面板刷新成本可控

### P2：把“UI 上限”和“无损采集上限”分离

如果用户要“持续精准采集”，只保留 `maxLogs=2000` 这类 UI 上限是不够的。

建议做法：

- 内存：只保留热点窗口
- 磁盘：增加 append-only journal / WAL
- 导出：从 journal 读
- 面板：只看 tail / filtered window

可以接受的折中是：

- UI 仍然只显示最近 N 条
- 但 session 内的全量事件写到本地 journal，必要时导出

### P3：把热路径数据改成 lazy materialization

建议：

- WebSocket 消息正文不要每条都拼接成完整大字符串
- 只存 message fragments 或 byte slices
- 进入详情页时再按需 join / decode
- HTTP body 超大时只存：
  - size
  - content type
  - preview
  - 磁盘偏移 / buffer handle

### P4：再评估 C++ / Rust

我的判断：

- `C++` 最适合做 JSI / NDK ingestion core
- `Rust` 最适合做 journal / index / query core
- 不建议“先全量重写再说”

最有价值的用法是：

- `C++`
  - lock-free ring buffer
  - JSI direct ingestion
  - Android / iOS 共用事件队列核心
- `Rust`
  - append-only WAL
  - query / replay / index
  - 可选压缩与持久化

### P5：如果只做一件事，先做这个

如果下个会话只推进一件高价值改动，建议直接做：

`Android Store 从全量 StateFlow 快照更新，改成 ring buffer + 可见窗口增量刷新`

这是现在最可能立刻带来明显收益的点。

## 下个会话建议的落地顺序

建议按这个顺序推进：

1. 先读本文件和以下文件：
   - `android/src/main/java/expo/modules/inappdebugger/InAppDebuggerStore.kt`
   - `android/src/main/java/expo/modules/inappdebugger/InAppDebuggerPanelDialogFragment.kt`
   - `src/internal/runtime.ts`
   - `src/internal/network.ts`
2. 先只做 Android
3. 第一阶段不要引入 C++ / Rust，先把 Kotlin 架构改正确
4. 做完第一阶段后再测：
   - 面板关闭时采集吞吐
   - 面板打开时高频日志 / WebSocket 滚动
   - 搜索和筛选开关切换时的 UI 响应
5. 如果第一阶段效果还不够，再开始设计 C++ JSI ingestion core

## 下个会话可直接使用的启动提示

可以直接这样开场：

```text
请先阅读 /Users/fiee/Projects/expo-inapp-debugger/HANDOFF.md，然后继续做 expo-inapp-debugger 的 Android 极致性能优化。要求是在持续精准采集不退让的前提下优化性能，优先只做 Android。先从 store / UI 更新链路入手，把当前全量 StateFlow 快照更新改成更低开销的 ring buffer + 增量窗口刷新；暂时不要先上 C++ / Rust，除非 Kotlin 架构优化已经完成且收益不够。改动后请至少跑 example/android 的 ./gradlew :app:compileDebugKotlin，并说明当前工作区里已存在未提交的 WebSocket / crash records 相关改动，不要误删。```

## 最后一次验证命令

```bash
cd /Users/fiee/Projects/expo-inapp-debugger
pnpm exec jest --runInBand
pnpm exec tsc -p tsconfig.json --noEmit
```

```bash
cd /Users/fiee/Projects/expo-inapp-debugger/example/android
./gradlew :app:compileDebugKotlin
```
