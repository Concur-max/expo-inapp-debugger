import * as React from 'react';
import {
  Platform,
  ScrollView,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';
import type { InAppDebugBoundaryProps } from './types';
import { inAppDebug } from './inAppDebug';
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

function DefaultErrorFallback({
  error,
  errorInfo,
  onRetry,
  showDebugInfo,
  strings,
}: {
  error: Error | null;
  errorInfo: React.ErrorInfo | null;
  onRetry: () => void;
  showDebugInfo: boolean;
  strings: typeof defaultStrings;
}) {
  return (
    <View style={styles.errorContainer}>
      <View style={styles.errorCard}>
        <View style={styles.badge}>
          <Text style={styles.badgeText}>BUG</Text>
        </View>
        <Text style={styles.errorTitle}>{strings.errorTitle}</Text>
        <Text style={styles.errorMessage}>
          {error?.message || strings.unknownError}
        </Text>

        {showDebugInfo && errorInfo?.componentStack ? (
          <ScrollView
            style={styles.debugInfo}
            contentContainerStyle={styles.debugInfoContent}
            showsVerticalScrollIndicator={false}
          >
            <Text style={styles.debugTitle}>{strings.errorDebugInfo}</Text>
            <Text style={styles.debugText}>{errorInfo.componentStack}</Text>
          </ScrollView>
        ) : null}

        <TouchableOpacity activeOpacity={0.85} onPress={onRetry} style={styles.retryButton}>
          <Text style={styles.retryButtonText}>{strings.errorRetry}</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
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

const styles = StyleSheet.create({
  errorContainer: {
    flex: 1,
    padding: 24,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#F5F1E8',
  },
  errorCard: {
    width: '100%',
    maxWidth: 420,
    borderRadius: 20,
    padding: 20,
    backgroundColor: '#FFFDF8',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: '#DED5C4',
    shadowColor: '#000000',
    shadowOpacity: 0.08,
    shadowOffset: { width: 0, height: 12 },
    shadowRadius: 24,
    elevation: 8,
  },
  badge: {
    alignSelf: 'flex-start',
    marginBottom: 12,
    paddingHorizontal: 10,
    paddingVertical: 6,
    borderRadius: 999,
    backgroundColor: '#E66000',
  },
  badgeText: {
    color: '#FFFFFF',
    fontSize: 12,
    fontWeight: '800',
    letterSpacing: 0.6,
  },
  errorTitle: {
    fontSize: 24,
    lineHeight: 30,
    fontWeight: '700',
    color: '#40210F',
    marginBottom: 10,
  },
  errorMessage: {
    fontSize: 16,
    lineHeight: 24,
    color: '#6A4F3B',
    marginBottom: 16,
  },
  debugInfo: {
    maxHeight: 220,
    borderRadius: 12,
    backgroundColor: '#F2ECE2',
  },
  debugInfoContent: {
    padding: 14,
  },
  debugTitle: {
    fontSize: 14,
    lineHeight: 20,
    fontWeight: '700',
    color: '#40210F',
    marginBottom: 8,
  },
  debugText: {
    fontSize: 12,
    lineHeight: 18,
    color: '#6A4F3B',
    fontFamily: Platform.select({
      ios: 'Menlo',
      android: 'monospace',
      default: 'monospace',
    }),
  },
  retryButton: {
    marginTop: 16,
    borderRadius: 14,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#1F6F5D',
    paddingVertical: 14,
  },
  retryButtonText: {
    color: '#FFFFFF',
    fontSize: 16,
    fontWeight: '700',
  },
});
