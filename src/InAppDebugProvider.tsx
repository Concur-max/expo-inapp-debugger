import * as React from 'react';
import type { InAppDebugProviderProps } from './types';
import { registerProviderConfig, unregisterProviderConfig } from './internal/singleton';
import { resolveProviderConfig } from './internal/runtime';
import { InAppDebugStringsContext } from './internal/strings';

export function InAppDebugProvider({
  children,
  enabled,
  initialVisible,
  enableNetworkTab,
  maxLogs,
  maxErrors,
  maxRequests,
  androidNativeLogs,
  locale,
  strings,
}: InAppDebugProviderProps) {
  const config = React.useMemo(
    () =>
      resolveProviderConfig({
        enabled,
        initialVisible,
        enableNetworkTab,
        maxLogs,
        maxErrors,
        maxRequests,
        androidNativeLogs,
        locale,
        strings,
      }),
    [
      enabled,
      initialVisible,
      enableNetworkTab,
      maxLogs,
      maxErrors,
      maxRequests,
      androidNativeLogs,
      locale,
      strings,
    ]
  );

  React.useEffect(() => {
    void registerProviderConfig(config);
    return () => {
      void unregisterProviderConfig();
    };
  }, [config]);

  return (
    <InAppDebugStringsContext.Provider value={config.strings}>
      {children}
    </InAppDebugStringsContext.Provider>
  );
}
