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

安装后需要重新构建原生 App：

```bash
npx expo prebuild
npx expo run:ios
# 或
npx expo run:android
```

如果你是 bare React Native 项目，请按项目自己的 iOS Pod / Android Gradle 流程重新安装和构建。

## 快速接入

在应用根部包一层 `InAppDebugProvider`。建议开发期启用，生产环境谨慎开启。

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

`InAppDebugRoot` 是默认推荐接入方式，内部等价于 `InAppDebugProvider + InAppDebugBoundary`。如果你已经有自己的 Error Boundary，或者只想接 Provider，也可以继续分别使用这两个组件。

`InAppDebugProvider` 默认是关闭的。只要挂载了 `InAppDebugProvider`，`enabled` 就是启停调试器的唯一权威开关。只有它变成 `true`，库才会创建运行时并安装 JS / native 采集 hook。

## 生产环境按需开启

如果你希望把库随生产包一起发布，但只给少量内部同学或测试账号开启，推荐把 `enabled` 绑定到业务开关，而不是直接跟 `__DEV__` 绑定：

```tsx
import { InAppDebugRoot } from 'expo-inapp-debugger';

export default function Root() {
  const debuggerEnabled =
    isInternalDeveloper && remoteConfig.inAppDebuggerEnabled;

  return (
    <InAppDebugRoot enabled={debuggerEnabled} locale="zh-CN">
      <App />
    </InAppDebugRoot>
  );
}
```

建议尽量在应用启动早期完成这个判断。这样命中的内部人员可以拿到更完整的启动期信息，而绝大部分 `enabled={false}` 的用户会保持休眠态。

库内部也会尽量延迟加载公共实现：如果只是 `import 'expo-inapp-debugger'`，但还没有实际渲染 `InAppDebugProvider` / `InAppDebugBoundary`，也没有调用 `InAppDebugController` / `inAppDebug`，入口不会立刻把对应实现模块全部求值。

## 关闭状态对宿主的影响

如果明确传入 `enabled={false}`，并且没有主动去挂载启用态的 Provider，调试器会保持休眠：

- 不 patch `console`、全局错误处理、Promise rejection 或 JS 网络拦截器。
- 不显示原生浮动按钮或调试面板。
- iOS 不开启 native log / URLProtocol / URLSession / WebSocket 采集。
- Android 不开启 logcat / stdout / stderr / uncaught exception / OkHttp 采集，也不会启动面板刷新用的后台线程。

这里的“关闭”指运行期不介入宿主逻辑。只要依赖仍然安装并被原生工程链接，它仍然会带来不可避免的包体、编译产物和 Expo module 注册成本。生产环境如果要求完全零体积、零注册成本，建议用 dev-only 入口或构建变体让生产包不安装 / 不导入这个库。

即使包入口已经被 `import`，只要还没有真正使用这些公共 API，JS 侧也会尽量保持惰性加载；但如果你已经真实挂载了 `InAppDebugProvider` / `InAppDebugBoundary`，仍然会有少量不可避免的 React 渲染与 Context 成本。要把关闭态开销压到最低，最推荐的仍然是先完成账号 / 远端开关判断，再决定是否导入并挂载这些组件。

如果曾经启用过，再把 Provider 的 `enabled` 切回 `false`，库会停止采集、隐藏 UI，并尽量释放已占用的 store / overlay / native log 资源；不过已经安装过的底层网络 hook 会进入快速跳过路径，这仍然和“进程启动后从未启用”不是同一个零介入状态。

## 面板说明

打开浮动按钮后会进入原生调试面板，当前主要有三个标签：

- `log`：JS console、React Error Boundary、全局错误、Promise rejection，以及 native 日志。
- `network`：fetch / XHR / WebSocket，以及平台可拦截到的 native 网络请求。
- `app Info`：宿主运行环境、调试器能力、采集状态、最近崩溃 / 严重错误、限制说明。

面板支持搜索、过滤、排序、复制、清空和网络详情查看。

不同 tab 也会影响采集强度：

- `log` 激活且 native 来源可见时，才会尽量启动较重的 native log 采集。
- `network` 激活时，才会尽量处理更完整的 native request / response payload preview。
- 不在对应 tab 时，会优先保留轻量元数据，尽量减少对宿主应用的影响。

## 可以采集什么

- JS 日志：`console.log/info/warn/error/debug`。
- JS 错误：全局 error、未处理 Promise rejection、React Error Boundary。
- 手动日志：通过 `inAppDebug.log()` 主动写入。
- 网络：JS fetch、XMLHttpRequest、WebSocket。
- iOS 原生：stdout、stderr、OSLog 轮询、未捕获 NSException、fatal signal 崩溃标记、部分 URLSession / WebSocket 信息。
- Android 原生：当前应用进程 logcat、stdout、stderr、未捕获 Java/Kotlin 异常，部分 OkHttp HTTP / WebSocket 信息。

为了降低对宿主应用的影响，部分 native 深度采集会根据面板是否打开、当前 tab 是否激活、过滤条件是否选择 native 来延迟启动或减少 payload preview。

## Provider 配置

```tsx
<InAppDebugProvider
  enabled={__DEV__}
  initialVisible
  enableNetworkTab
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
| `enableNetworkTab` | `true` | 是否启用网络面板和网络采集。 |
| `maxLogs` | `2000` | 保留的最大日志数量。 |
| `maxErrors` | `100` | 保留的最大错误数量。 |
| `maxRequests` | `100` | 保留的最大网络请求数量。 |
| `locale` | `auto` | 支持 `auto`、`zh-CN`、`zh-TW`、`en-US`、`ja`。 |
| `strings` | - | 覆盖默认文案。 |
| `androidNativeLogs` | 见下方 | Android 原生日志配置。 |

## React Error Boundary

`InAppDebugBoundary` 会捕获 React 渲染错误，并把错误写入调试面板。

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

Android 默认会采集当前 App 进程相关的 native 日志：

- app 进程 `logcat`
- `stdout`
- `stderr`
- 未捕获 Java / Kotlin 异常，并在下次启动时回放崩溃记录

可以通过 Provider 调整：

```tsx
<InAppDebugProvider
  enabled
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

- 调试器启用后会提前准备 native crash 持久化，尽量避免“崩了但下次打开什么都没有”。
- stdout / stderr / OSLog 等较重采集只在 `log` 面板且 native 来源激活时运行。
- native 网络 payload preview 只在 `network` 面板激活时尽量处理，平时优先记录轻量元数据。
- iOS 系统限制较多，无法保证回放调试器启动之前的任意日志，但会尽力保留未捕获崩溃报告。

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
- 推荐用远程配置、隐藏手势或内部构建开关控制 `enabled`。
- `maxLogs`、`maxRequests` 不要无限调大。当前 native store 使用固定容量 ring buffer，但 UI 展示和搜索仍然会受数量影响。
- 如果只排查 JS 问题，可以关闭 native 来源过滤或关闭 network 面板，减少额外采集。

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
