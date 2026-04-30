import { configureInAppDebugBootstrap } from 'expo-inapp-debugger';

configureInAppDebugBootstrap({
  enabled: __DEV__,
});
