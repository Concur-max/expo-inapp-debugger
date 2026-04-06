import * as React from 'react';
import {
  Alert,
  ScrollView,
  StatusBar,
  StyleSheet,
  Switch,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';
import {
  InAppDebugBoundary,
  InAppDebugController,
  InAppDebugProvider,
  inAppDebug,
} from 'expo-inapp-debugger';

function DemoCrash({ shouldCrash }: { shouldCrash: boolean }) {
  if (shouldCrash) {
    throw new Error('示例页主动触发的渲染崩溃');
  }
  return null;
}

export default function App() {
  const [enabled, setEnabled] = React.useState(true);
  const [shouldCrash, setShouldCrash] = React.useState(false);
  const socketRef = React.useRef<WebSocket | null>(null);

  const logMessage = React.useCallback((type: 'log' | 'info' | 'warn' | 'debug' | 'error') => {
    const payload = {
      now: new Date().toISOString(),
      platform: '示例应用',
      random: Math.round(Math.random() * 1000),
    };
    if (type === 'log') console.log('示例 Console Log', payload);
    if (type === 'info') console.info('示例 Console Info', payload);
    if (type === 'warn') console.warn('示例 Console Warn', payload);
    if (type === 'debug') console.debug('示例 Console Debug', payload);
    if (type === 'error') console.error('示例 Console Error', payload);
  }, []);

  const makeRequest = React.useCallback(async () => {
    try {
      const response = await fetch('https://jsonplaceholder.typicode.com/todos/1');
      const json = await response.json();
      console.info('Fetch 请求成功', json);
    } catch (error) {
      console.error('HTTP 请求失败', error);
    }
  }, []);

  const connectSocket = React.useCallback(() => {
    socketRef.current?.close();
    const socket = new WebSocket('wss://echo.websocket.events');
    socketRef.current = socket;

    socket.onopen = () => {
      console.info('WebSocket 已连接');
      socket.send(`来自示例应用的消息 ${Date.now()}`);
    };
    socket.onmessage = (event) => {
      console.info('WebSocket 消息', event.data);
    };
    socket.onerror = (event) => {
      console.error('WebSocket 错误', event);
    };
    socket.onclose = (event) => {
      console.warn('WebSocket 已关闭', event.code, event.reason);
    };
  }, []);

  const captureManualError = React.useCallback(() => {
    inAppDebug.captureError('manual', '示例页面手动注入了一条错误');
    Alert.alert('手动错误', '已向调试器写入一条手动错误记录。');
  }, []);

  React.useEffect(() => {
    return () => {
      socketRef.current?.close();
    };
  }, []);

  return (
    <InAppDebugProvider enabled={enabled} initialVisible enableNetworkTab>
      <InAppDebugBoundary>
        <StatusBar barStyle="dark-content" />
        <View style={styles.safeArea}>
          <DemoCrash shouldCrash={shouldCrash} />
          <ScrollView contentContainerStyle={styles.container}>
            <Text style={styles.kicker}>expo-inapp-debugger</Text>
            <Text style={styles.title}>原生应用内调试示例</Text>
            <Text style={styles.subtitle}>
              通过下面的操作可以生成 Console 日志、网络请求、React 错误和手动记录。
              悬浮原生调试器也可以通过控制器随时显示或隐藏。
            </Text>

            <View style={styles.switchRow}>
              <View>
                <Text style={styles.switchLabel}>启用调试器</Text>
                <Text style={styles.switchHint}>
                  关闭后可以验证接近 release 场景下的空闲行为。
                </Text>
              </View>
              <Switch value={enabled} onValueChange={setEnabled} />
            </View>

            <View style={styles.grid}>
              <ActionButton label="触发 Console Log" onPress={() => logMessage('log')} />
              <ActionButton label="触发 Console Info" onPress={() => logMessage('info')} />
              <ActionButton label="触发 Console Warn" onPress={() => logMessage('warn')} />
              <ActionButton label="触发 Console Debug" onPress={() => logMessage('debug')} />
              <ActionButton label="触发 Console Error" onPress={() => logMessage('error')} />
              <ActionButton label="发起 Fetch 请求" onPress={makeRequest} />
              <ActionButton label="连接 WebSocket" onPress={connectSocket} />
              <ActionButton label="写入手动错误" onPress={captureManualError} />
              <ActionButton label="触发渲染崩溃" onPress={() => setShouldCrash(true)} tone="danger" />
              <ActionButton label="显示调试器" onPress={() => void InAppDebugController.show()} />
              <ActionButton label="隐藏调试器" onPress={() => void InAppDebugController.hide()} />
              <ActionButton
                label="导出快照"
                onPress={async () => {
                  const snapshot = await InAppDebugController.exportSnapshot();
                  Alert.alert(
                    '快照已导出',
                    `日志: ${snapshot.logs.length}\n错误: ${snapshot.errors.length}\n网络: ${snapshot.network.length}`
                  );
                }}
              />
              <ActionButton
                label="清空全部"
                onPress={() => void InAppDebugController.clear('all')}
                tone="secondary"
              />
            </View>
          </ScrollView>
        </View>
      </InAppDebugBoundary>
    </InAppDebugProvider>
  );
}

function ActionButton({
  label,
  onPress,
  tone = 'primary',
}: {
  label: string;
  onPress: () => void | Promise<void>;
  tone?: 'primary' | 'secondary' | 'danger';
}) {
  return (
    <TouchableOpacity
      activeOpacity={0.82}
      onPress={() => void onPress()}
      style={[
        styles.button,
        tone === 'primary' && styles.primaryButton,
        tone === 'secondary' && styles.secondaryButton,
        tone === 'danger' && styles.dangerButton,
      ]}
    >
      <Text
        style={[
          styles.buttonText,
          tone === 'secondary' ? styles.secondaryButtonText : null,
        ]}
      >
        {label}
      </Text>
    </TouchableOpacity>
  );
}

const styles = StyleSheet.create({
  safeArea: {
    flex: 1,
    backgroundColor: '#F5F1E8',
  },
  container: {
    padding: 20,
    gap: 18,
  },
  kicker: {
    fontSize: 13,
    fontWeight: '700',
    color: '#1F6F5D',
    textTransform: 'uppercase',
    letterSpacing: 1.1,
  },
  title: {
    fontSize: 30,
    lineHeight: 36,
    fontWeight: '800',
    color: '#2B221B',
  },
  subtitle: {
    fontSize: 16,
    lineHeight: 24,
    color: '#66584A',
  },
  switchRow: {
    borderRadius: 18,
    padding: 16,
    backgroundColor: '#FFFDF8',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: '#D8D0C3',
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 16,
  },
  switchLabel: {
    fontSize: 16,
    fontWeight: '700',
    color: '#2B221B',
  },
  switchHint: {
    marginTop: 4,
    color: '#66584A',
    lineHeight: 20,
  },
  grid: {
    gap: 12,
  },
  button: {
    minHeight: 52,
    borderRadius: 16,
    paddingHorizontal: 16,
    alignItems: 'center',
    justifyContent: 'center',
  },
  primaryButton: {
    backgroundColor: '#1F6F5D',
  },
  secondaryButton: {
    backgroundColor: '#E6DED1',
  },
  dangerButton: {
    backgroundColor: '#B93822',
  },
  buttonText: {
    color: '#FFFFFF',
    fontSize: 16,
    fontWeight: '700',
  },
  secondaryButtonText: {
    color: '#2B221B',
  },
});
