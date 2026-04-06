import * as React from 'react';
import type { InAppDebugProviderProps } from './types';
import { debugRuntime } from './internal/singleton';
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
        locale,
        strings,
      }),
    [enabled, initialVisible, enableNetworkTab, maxLogs, maxErrors, maxRequests, locale, strings]
  );

  React.useEffect(() => {
    void debugRuntime.registerProvider(config);
    return () => {
      void debugRuntime.unregisterProvider();
    };
  }, [config]);

  return (
    <InAppDebugStringsContext.Provider value={config.strings}>
      {children}
    </InAppDebugStringsContext.Provider>
  );
}
