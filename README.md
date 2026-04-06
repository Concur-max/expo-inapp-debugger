# expo-inapp-debugger

Native in-app debugging toolkit for Expo prebuild/dev build and bare React Native apps.

## Features

- Native floating entry button on Android and iOS
- Native full-screen debug panel
- Console, global error, promise rejection, React error boundary capture
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
