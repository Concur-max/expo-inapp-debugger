# expo-inapp-debugger

Native in-app debugging toolkit for Expo prebuild/dev build and bare React Native apps.

## Features

- Native floating entry button on Android and iOS
- Native full-screen debug panel
- Console, global error, promise rejection, React error boundary capture
- Android native log capture for app `logcat`, `stdout`, `stderr`, and uncaught exceptions
- JS networking capture for `XMLHttpRequest` and `WebSocket`
- Search, level filtering, sorting, copy, clear, and snapshot export

## Public API

```tsx
import {
  InAppDebugBoundary,
  InAppDebugController,
  InAppDebugProvider,
  inAppDebug,
} from 'expo-inapp-debugger';
```

`InAppDebugProvider` is disabled by default. The library only installs JS/native capture hooks after you explicitly pass `enabled={true}` or call the controller to enable it at runtime.

```tsx
<InAppDebugProvider enabled={__DEV__ && debugFlag}>
  <App />
</InAppDebugProvider>
```

### Android Native Logs

Android now captures native logs from the current app process by default whenever the debugger is enabled. That includes:

- app-process `logcat`
- `stdout`
- `stderr`
- uncaught Java/Kotlin exceptions, with replay on the next launch

You can tune Android native capture from the provider:

```tsx
<InAppDebugProvider
  enabled
  androidNativeLogs={{
    logcatScope: 'app',
    rootMode: 'off',
    buffers: ['main', 'system', 'crash'],
  }}
>
  <App />
</InAppDebugProvider>
```

If your device is rooted and you want a broader `logcat` reader, opt into the root-enhanced mode:

```tsx
InAppDebugController.configureAndroidNativeLogs({
  logcatScope: 'device',
  rootMode: 'auto',
  buffers: ['main', 'system', 'crash'],
});
```

`rootMode: 'auto'` is an explicit opt-in. If root is unavailable or denied, the Android collector falls back to app-only `logcat`.

## Example

See [`example/App.tsx`](./example/App.tsx) for a minimal integration.

## Running The Example

This package targets Expo prebuild / dev build and bare React Native. Expo Go is not supported.

From a fresh checkout:

```bash
cd example
pnpm install
npx expo prebuild
npx expo run:ios
# or
npx expo run:android
```

After the native shell is installed, keep Metro running in a separate terminal:

```bash
cd example
pnpm start
```

For real-device LAN debugging, keep the phone and Mac on the same network and start Metro with:

```bash
cd example
pnpm start:lan
```

The example uses `expo-inapp-debugger-example` as its dev-client URI scheme.

If you see `No script URL provided`, the native app started without a Metro bundle URL. Start Metro with `pnpm start` and relaunch the installed app, or rebuild with `npx expo run:ios` / `npx expo run:android`.
