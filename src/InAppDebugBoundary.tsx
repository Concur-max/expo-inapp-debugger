import * as React from 'react';
import type { InAppDebugBoundaryProps } from './types';
import { defaultStrings, InAppDebugStringsContext } from './internal/strings';

type InAppDebugBoundaryState = {
  hasError: boolean;
  error: Error | null;
  errorInfo: React.ErrorInfo | null;
};

function resolveShowDebugInfo(showDebugInfo?: boolean) {
  if (typeof showDebugInfo === 'boolean') {
    return showDebugInfo;
  }
  return typeof __DEV__ !== 'undefined' ? __DEV__ : false;
}

export class InAppDebugBoundary extends React.Component<
  InAppDebugBoundaryProps,
  InAppDebugBoundaryState
> {
  static contextType = InAppDebugStringsContext;

  state: InAppDebugBoundaryState = {
    hasError: false,
    error: null,
    errorInfo: null,
  };

  static getDerivedStateFromError(error: Error): Partial<InAppDebugBoundaryState> {
    return {
      hasError: true,
      error,
    };
  }

  componentDidCatch(error: Error, errorInfo: React.ErrorInfo) {
    const { inAppDebug } = require('./inAppDebug') as typeof import('./inAppDebug');
    inAppDebug.captureError(
      'react',
      `React Error: ${error.message}`,
      `Component Stack: ${errorInfo.componentStack}`,
      `Error Stack: ${error.stack || ''}`
    );

    this.setState({
      error,
      errorInfo,
    });

    this.props.onError?.(error, errorInfo);
  }

  private handleRetry = () => {
    this.setState({
      hasError: false,
      error: null,
      errorInfo: null,
    });
  };

  render() {
    const strings =
      (this.context as React.ContextType<typeof InAppDebugStringsContext>) ?? defaultStrings;

    if (!this.state.hasError) {
      return this.props.children;
    }

    if (this.props.fallback) {
      return this.props.fallback(this.state.error, this.state.errorInfo, this.handleRetry);
    }

    const { DefaultErrorFallback } = require('./internal/boundaryFallback') as typeof import('./internal/boundaryFallback');

    return (
      <DefaultErrorFallback
        error={this.state.error}
        errorInfo={this.state.errorInfo}
        onRetry={this.handleRetry}
        showDebugInfo={resolveShowDebugInfo(this.props.showDebugInfo)}
        strings={strings}
      />
    );
  }
}
