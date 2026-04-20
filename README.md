# expo-inapp-debugger

一个给 Expo / React Native 应用使用的应用内调试工具。

它会在宿主 App 内放一个原生浮动入口，打开后可以直接查看 JS 日志、React 错误、全局异常、网络请求、WebSocket、原生日志，以及基础 App 运行信息。适合 dev build、prebuild、bare React Native 场景下排查“用户设备上临时出事，但电脑不在身边”的问题。

> 注意：这个库包含 iOS / Android 原生代码，Expo Go 不支持。请使用 Expo Dev Client、Expo prebuild，或 bare React Native。

## 安装

```bash
pnpm add expo-inapp-debugger
```

也可以使用 npm / yarn / bun：

```bash
npm install expo-inapp-debugger
yarn add expo-inapp-debugger
bun add expo-inapp-debugger
```

仓库维护时如果需要发布 npm 新版本，可参考 [RELEASE.md](./RELEASE.md)。

安装后需要重新构建原生 App：

```bash
npx expo prebuild
npx expo run:ios
# 或
npx expo run:android
```

如果你是 bare React Native 项目，请按项目自己的 iOS Pod / Android Gradle 流程重新安装和构建。

## 快速接入

最简单的默认接入方式是一层 `InAppDebugRoot`：

```tsx
import { InAppDebugRoot } from 'expo-inapp-debugger';

export default function Root() {
  return (
    <InAppDebugRoot enabled={__DEV__} locale="zh-CN">
      <App />
    </InAppDebugRoot>
  );
}
```

`InAppDebugRoot` 内部等价于 `InAppDebugProvider + InAppDebugBoundary`。它适合想要“开箱即用”拿到调试器和 React Error Boundary 的场景。

如果你把“未启用时尽量不改变宿主功能”作为硬约束，生产环境更推荐只挂 `InAppDebugProvider`，继续沿用宿主自己现有的 Error Boundary：

```tsx
import { InAppDebugProvider } from 'expo-inapp-debugger';

export default function Root() {
  return (
    <InAppDebugProvider enabled={__DEV__} locale="zh-CN">
      <App />
    </InAppDebugProvider>
  );
}
```

原因是：`InAppDebugBoundary` 是一个真实的 React Error Boundary。即使 `enabled={false}`，它也仍然会捕获 React 渲染错误并渲染 fallback UI，只是“写入调试面板”这一步在 runtime 未创建时会变成 no-op。

可以把三种接入方式理解成下面这样：

| 方式 | 适用场景 | 对宿主功能的影响 | 关闭态开销 |
| --- | --- | --- | --- |
| `InAppDebugRoot` | 默认最简单接入 | 会额外引入一个 React Error Boundary | 比 `Provider` 略高，但通常仍很低 |
| `InAppDebugProvider` | 生产环境最稳妥、最小语义影响 | 不改变 React 错误处理语义 | 低 |
| `InAppDebugBoundary` | 只想单独使用内置 Error Boundary | 会改变 React 渲染错误的处理方式 | 与调试器是否启用无强绑定 |

`InAppDebugProvider` 默认是关闭的。只要挂载了 `InAppDebugProvider`，`enabled` 就是启停调试器的唯一权威开关。只有它变成 `true`，库才会创建运行时并安装 React Native 日志与网络采集。原生日志 / 原生网络采集默认关闭，需要在 App Info 面板里显式打开，或通过 Provider 显式传入 opt-in 配置。

## 生产环境按需开启

如果你希望把库随生产包一起发布，但只给少量内部同学或测试账号开启，推荐把 `enabled` 绑定到业务开关，而不是直接跟 `__DEV__` 绑定。

对绝大部分生产项目，推荐优先级是这样的：

1. 最优策略：账号命中前不要 `import`，不要挂 `Provider`，不要挂 `Boundary`。
2. 次优策略：可以先 `import` 包，但只挂 `InAppDebugProvider enabled={debuggerEnabled}`。
3. 最简单策略：使用 `InAppDebugRoot`，前提是你接受它自带的 Boundary 语义。

如果你追求“未命中账号时运行期开销无限逼近 0”，可以把导入也延后到命中后再发生：

```tsx
export default function Root() {
  const debuggerEnabled =
    isInternalDeveloper && remoteConfig.inAppDebuggerEnabled;

  if (!debuggerEnabled) {
    return <App />;
  }

  const { InAppDebugRoot } = require('expo-inapp-debugger');
  return (
    <InAppDebugRoot enabled locale="zh-CN">
      <App />
    </InAppDebugRoot>
  );
}
```

如果你不想把 import 延后，至少建议这样做：

```tsx
import { InAppDebugProvider } from 'expo-inapp-debugger';

export default function Root() {
  const debuggerEnabled =
    isInternalDeveloper && remoteConfig.inAppDebuggerEnabled;

  return (
    <InAppDebugProvider enabled={debuggerEnabled} locale="zh-CN">
      <App />
    </InAppDebugProvider>
  );
}
```

建议尽量在应用启动早期完成这个判断。这样命中的内部人员可以拿到更完整的启动期信息，而绝大部分 `enabled={false}` 的用户会保持休眠态。

库内部也会尽量延迟加载公共实现：如果只是 `import 'expo-inapp-debugger'`，但还没有实际渲染 `InAppDebugProvider` / `InAppDebugBoundary` / `InAppDebugRoot`，也没有调用 `InAppDebugController` / `inAppDebug`，入口不会立刻把对应实现模块全部求值。

## 真实开销模型

下面的说明基于当前仓库代码路径，是“真实行为分层”，不是承诺某个固定的毫秒或内存数字。具体体感仍然会受宿主 App 规模、React Native 版本、设备性能和业务初始化逻辑影响。

| 状态 | 真实行为 | 是否通常可忽略 |
| --- | --- | --- |
| 生产包根本不安装本库 | 没有任何库相关 JS / native 运行期开销，也没有原生模块注册成本 | 是 |
| 已安装到生产包，但当前进程没有 import 本库 | 仍然有包体、原生链接、Expo module 注册成本；没有本库 JS runtime 成本 | 对业务运行通常可忽略，但不是零体积 |
| 已 import 包，但没有渲染 `Provider` / `Boundary` / `Root`，也没有调用任何 API | 只有入口包装模块求值；不会创建 `DebugRuntime`，不会安装采集 hook | 通常可忽略 |
| 渲染 `InAppDebugProvider enabled={false}`，且本进程从未启用过 | 会有少量 React render、effect、配置解析、Context 成本；不会创建 runtime，也不会安装 collectors | 通常可忽略 |
| 渲染 `InAppDebugRoot enabled={false}`，且本进程从未启用过 | 在上一行基础上，再多一个 Boundary 组件；同时 React 渲染错误处理语义会改变 | 性能通常可忽略，但功能影响不是零 |
| `enabled={true}`，未显式开启 native 采集 | 会创建 runtime，安装 JS console / error / promise / fetch / XHR / WebSocket 采集；native logs / native network 保持关闭 | 有明确调试开销，但默认避开最重的原生 hook |
| `enabled={true}`，并在 App Info 或 Provider 中开启 native 采集 | 在上一行基础上开启对应 native collector；iOS native network 会安装 URLProtocol / URLSession hook，Android native network 会启用 OkHttp 采集路径 | 不能视为可忽略，只建议临时排查 |
| 同一进程里曾启用过 native network，之后又切回关闭 | 重采集会停止，UI/store 会释放；但 runtime 对象仍在，部分底层 native 网络 hook 可能会留在快速跳过路径 | 对普通业务通常很低，但不等于“从未启用 native network” |
| 上一行之后再把应用进程杀掉并重启，且新进程里 `enabled={false}` | 会回到“新进程从未启用”的关闭态，只保留包体和原生注册这类构建级成本 | 通常可认为接近最干净关闭态 |

如果明确传入 `enabled={false}`，并且没有主动去挂载启用态的 Provider，调试器会保持休眠：

- 不 patch `console`、全局错误处理、Promise rejection 或 JS 网络拦截器。
- 不显示原生浮动按钮或调试面板。
- iOS 不开启 native log / URLProtocol / URLSession / WebSocket 采集。
- Android 不开启 logcat / stdout / stderr / uncaught exception / OkHttp 采集，也不会启动面板刷新用的后台线程。

这里的“关闭”指运行期尽量不介入宿主逻辑。只要依赖仍然安装并被原生工程链接，它仍然会带来不可避免的包体、编译产物和 Expo module 注册成本。生产环境如果要求完全零体积、零注册成本，建议用 dev-only 入口或构建变体让生产包不安装这个库。

## 运行时 API 与懒加载行为

当前代码行为可以总结为：

- 只要 `InAppDebugProvider` 已经挂载，`enabled` 就是唯一权威开关。
- `InAppDebugController.enable()` / `disable()` 只作为“不挂 Provider 时”的兼容入口保留；一旦 Provider 已经挂载，这两个方法不会再覆盖 Provider 的状态。
- `InAppDebugController.show()` / `hide()` / `clear()` / `exportSnapshot()` / `configureAndroidNativeLogs()` 第一次调用时，会创建一个 `DebugRuntime` 对象；但如果当前并未启用调试器，它们不会因此安装 collectors。
- `inAppDebug.log()` / `inAppDebug.captureError()` 不会主动创建 runtime；如果 runtime 还不存在，它们会直接 no-op。
- `InAppDebugBoundary` / `InAppDebugRoot` 会一直作为 React Error Boundary 存在，不以 `enabled` 为前提。
- 原生日志 / 原生网络是独立 opt-in：默认只采集 React Native 层日志和网络；App Info 里的开关只影响当前调试会话。

如果你的目标是把关闭态开销压到最低，普通用户路径上应尽量避免调用任何 `InAppDebugController` API。

## 切账号、退出登录与进程重启

如果一个用户在当前进程里登录过开发账号并启用过调试器，之后退出登录并切回普通账号：

- 只要 Provider 的 `enabled` 重新变成 `false`，重采集部分就会停掉。
- 但这时同一进程里并不会完全回到“从未启用”的最干净状态。
- JS 侧已经创建过的 `DebugRuntime` 对象会继续留在内存里。
- 如果当前进程里曾显式开启过 native network，Android / iOS 底层 native 网络 hook 不会反安装，而是进入快速跳过路径。
- 如果当前进程里曾显式开启过 iOS native logs，native crash / signal handler 会继续留到进程结束。

这类“历史启用残留”通常已经低到可以在普通业务路径里近似忽略，但如果你要求回到最接近“从未启用”的状态，最稳妥的方式仍然是让应用进程结束后重新进入。

## 面板说明

打开浮动按钮后会进入原生调试面板，当前主要有三个标签：

- `log`：JS console、React Error Boundary、全局错误、Promise rejection；显式开启后也可以查看 native 日志。
- `network`：React Native fetch / XHR / WebSocket；显式开启后也可以查看平台可拦截到的 native 网络请求。
- `app Info`：宿主运行环境、调试器能力、采集状态、native logs / native network 开关、最近崩溃 / 严重错误、限制说明。

面板支持搜索、过滤、排序、复制、清空和网络详情查看。

不同 tab 也会影响采集强度：

- native logs 默认关闭；在 App Info 打开后，`log` 激活且 native 来源可见时才会启动较重的 native log 采集。
- native network 默认关闭；在 App Info 打开后，`network/native` 激活时才会尽量处理更完整的 native request / response payload preview。
- 不在对应 tab 时，会优先保留轻量元数据，尽量减少对宿主应用的影响。

## 可以采集什么

- JS 日志：`console.log/info/warn/error/debug`。
- JS 错误：全局 error、未处理 Promise rejection、React Error Boundary。
- 手动日志：通过 `inAppDebug.log()` 主动写入。
- 网络：JS fetch、XMLHttpRequest、WebSocket。
- iOS 原生（显式开启后）：stdout、stderr、OSLog 轮询、未捕获 NSException、fatal signal 崩溃标记、部分 URLSession 信息。
- Android 原生（显式开启后）：当前应用进程 logcat、stdout、stderr、未捕获 Java/Kotlin 异常，部分 OkHttp HTTP / WebSocket 信息。

如果 Android 宿主 App、原生模块，或接入的部分 SDK 会自己创建 `OkHttpClient`，可以在创建 client 时走一次官方 helper。只有 App Info 中打开 `Native network` 后，这批 native 请求才会并入调试面板；关闭时 helper 只走快速跳过路径：

```kotlin
import expo.modules.inappdebugger.InAppDebuggerOkHttpIntegration
import okhttp3.OkHttpClient

val client =
  InAppDebuggerOkHttpIntegration
    .newBuilder()
    .build()
```

如果你已经有现成的 `OkHttpClient.Builder` / `OkHttpClient`，也可以直接包一层：

```kotlin
val builder = OkHttpClient.Builder()
InAppDebuggerOkHttpIntegration.instrument(builder)

val client = OkHttpClient()
val instrumentedClient = InAppDebuggerOkHttpIntegration.instrument(client)
```

这条路径适合“宿主自己可控、但不一定走 React Native 默认网络模块”的 Android native 请求。它仍然不是系统级全抓；`OkHttp` 之外的网络栈，例如 `HttpURLConnection`、`Cronet` 或某些黑盒 SDK 自带实现，仍然需要单独适配。

为了降低对宿主应用的影响，native 深度采集默认不启动；显式开启后，还会继续根据面板是否打开、当前 tab 是否激活、过滤条件是否选择 native 来延迟启动或减少 payload preview。

## Provider 配置

```tsx
<InAppDebugProvider
  enabled={__DEV__}
  initialVisible
  enableNetworkTab
  enableNativeLogs={false}
  enableNativeNetwork={false}
  maxLogs={2000}
  maxErrors={100}
  maxRequests={100}
  locale="zh-CN"
>
  <App />
</InAppDebugProvider>
```

常用参数：

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `enabled` | `false` | 是否启用调试器。关闭时不会安装采集 hook。 |
| `initialVisible` | `true` | 是否显示原生浮动入口。 |
| `enableNetworkTab` | `true` | 是否启用网络面板和 React Native 网络采集。 |
| `enableNativeLogs` | `false` | 是否在启动时直接开启原生日志采集。通常推荐保持默认值，在 App Info 中临时打开。 |
| `enableNativeNetwork` | `false` | 是否在启动时直接开启原生网络采集。通常推荐保持默认值，在 App Info 中临时打开。 |
| `maxLogs` | `2000` | 保留的最大日志数量。 |
| `maxErrors` | `100` | 保留的最大错误数量。 |
| `maxRequests` | `100` | 保留的最大网络请求数量。 |
| `locale` | `auto` | 支持 `auto`、`zh-CN`、`zh-TW`、`en-US`、`ja`。 |
| `strings` | - | 覆盖默认文案。 |
| `androidNativeLogs` | 见下方 | Android 原生日志配置。 |

## React Error Boundary

`InAppDebugBoundary` 会捕获 React 渲染错误，并把错误写入调试面板。

需要特别注意的是：它不依赖 `enabled` 才生效。只要你挂载了 `InAppDebugBoundary`，宿主的 React 渲染错误处理语义就已经发生了变化。

```tsx
<InAppDebugBoundary
  showDebugInfo={__DEV__}
  onError={(error, errorInfo) => {
    // 这里仍然可以接你的 Sentry / 自建上报
  }}
>
  <App />
</InAppDebugBoundary>
```

也可以自定义 fallback：

```tsx
<InAppDebugBoundary
  fallback={(error, errorInfo, retry) => (
    <ErrorScreen error={error} onRetry={retry} />
  )}
>
  <App />
</InAppDebugBoundary>
```

## 手动写入日志和错误

```tsx
import { inAppDebug } from 'expo-inapp-debugger';

inAppDebug.log('info', '用户点击了支付按钮', {
  orderId: 'order_123',
});

inAppDebug.captureError('global', '支付流程异常', error);
```

`inAppDebug.log(level, ...args)` 的 `level` 支持：

```ts
'log' | 'info' | 'warn' | 'error' | 'debug'
```

## 运行时控制

```tsx
import { InAppDebugController } from 'expo-inapp-debugger';

await InAppDebugController.show();
await InAppDebugController.hide();

await InAppDebugController.clear('logs');
await InAppDebugController.clear('network');
await InAppDebugController.clear('all');

const snapshot = await InAppDebugController.exportSnapshot();
console.log(snapshot.logs, snapshot.errors, snapshot.network);
```

如果你已经挂载了 `InAppDebugProvider`，请优先通过它的 `enabled` prop 控制启停，不要再混用 `InAppDebugController.enable()` / `disable()`。

`enable()` / `disable()` 仅作为“不挂 Provider 时”的兼容入口保留；一旦 Provider 已经挂载，这两个方法会让位给 Provider，不再覆盖它的状态。

`exportSnapshot()` 会返回：

```ts
{
  logs: DebugLogEntry[];
  errors: DebugErrorEntry[];
  network: DebugNetworkEntry[];
  exportTime: string;
}
```

## Android 原生日志

Android 原生日志默认关闭。需要时可以在 App Info 面板中打开 `Native logs`，或者通过 Provider 显式 opt-in。开启后可以采集当前 App 进程相关的 native 日志：

- app 进程 `logcat`
- `stdout`
- `stderr`
- 未捕获 Java / Kotlin 异常，并在下次启动时回放崩溃记录

可以通过 Provider 调整：

```tsx
<InAppDebugProvider
  enabled
  enableNativeLogs
  androidNativeLogs={{
    enabled: true,
    captureLogcat: true,
    captureStdoutStderr: true,
    captureUncaughtExceptions: true,
    logcatScope: 'app',
    rootMode: 'off',
    buffers: ['main', 'system', 'crash'],
  }}
>
  <App />
</InAppDebugProvider>
```

如果测试机已经 root，并且你明确希望读取更广的设备级 logcat，可以手动开启 root 增强模式：

```tsx
import { InAppDebugController } from 'expo-inapp-debugger';

await InAppDebugController.configureAndroidNativeLogs({
  logcatScope: 'device',
  rootMode: 'auto',
  buffers: ['main', 'system', 'crash'],
});
```

Android 面板的 `app Info` 里也提供了 root 增强模式开关，方便在设备上临时打开。

`rootMode: 'auto'` 是显式 opt-in。如果 root 不可用、授权失败或被拒绝，会回退到 app-only logcat。

## iOS 注意事项

iOS 侧会尽量保留低开销策略：

- 原生日志默认关闭；打开 App Info 的 `Native logs` 后，才会准备 native crash 持久化和相关日志采集。
- stdout / stderr / OSLog 等较重采集只在 `Native logs` 已开启、`log` 面板且 native 来源激活时运行。
- 原生网络默认关闭；打开 App Info 的 `Native network` 后，才会安装 URLProtocol / URLSession 相关采集路径。
- native 网络 payload preview 只在 `Native network` 已开启且 `network/native` 面板激活时尽量处理，平时优先记录轻量元数据。
- iOS 系统限制较多，无法保证回放调试器启动之前的任意日志，但会尽力保留未捕获崩溃报告。

补充说明：一旦当前进程里启用过 iOS native log capture，崩溃 / signal handler 会保留到该进程结束。因此“启用过再关闭”在同一进程里仍然不等于“从未启用过”。

## 网络面板说明

网络面板会展示：

- 请求来源：`JS` / `native`
- 请求类型：XHR / Fetch / WebSocket / native
- method、status、state、duration
- request / response headers
- request / response body preview
- WebSocket message / event summary

并不是所有 native 网络库都能被完整拦截。系统 API、第三方库、React Native 版本、平台安全策略都会影响可见范围。调试器会尽量采集已知路径，但不能替代代理抓包工具。

## 性能建议

- 不要默认在生产环境全量开启，除非你明确接受日志与网络内容被本地记录的风险。
- 如果“未启用时几乎零影响”是第一优先级，优先做到“账号命中前不 import、不挂 Provider、不挂 Boundary”。
- 如果需要长期把库随正式包带上，生产环境优先考虑 `InAppDebugProvider`，而不是 `InAppDebugRoot`。
- 普通用户路径上避免调用 `InAppDebugController.show()` / `exportSnapshot()` 等 API，因为它们会创建 runtime 对象。
- `maxLogs`、`maxRequests` 不要无限调大。当前 native store 使用固定容量 ring buffer，但 UI 展示和搜索仍然会受数量影响。
- 如果只排查 JS 问题，可以关闭 network 面板或减少 native 来源采集，进一步压低开销。

## 示例工程

仓库内置了 example：

```bash
cd example
pnpm install
npx expo prebuild
npx expo run:ios
# 或
npx expo run:android
```

安装 dev client 后，另开终端启动 Metro：

```bash
cd example
pnpm start
```

真机局域网调试可以使用：

```bash
cd example
pnpm start:lan
```

example 里还带了本地 HTTP / WebSocket mock server，方便测试 network 面板：

```bash
cd example
pnpm http:mock
pnpm ws:echo
```

如果看到 `No script URL provided`，说明原生 App 启动时没有拿到 Metro bundle URL。请先启动 Metro，再重新打开已安装的 dev client；必要时重新执行 `npx expo run:ios` 或 `npx expo run:android`。

## 本地验证

发布或提交前建议跑：

```bash
pnpm typecheck
pnpm test
npm pack --dry-run
```

iOS 改动建议额外跑：

```bash
xcodebuild -workspace example/ios/ExpoInAppDebuggerExample.xcworkspace \
  -scheme ExpoInAppDebuggerExample \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  build
```

## License

MIT
