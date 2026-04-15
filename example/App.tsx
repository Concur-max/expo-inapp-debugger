import * as React from 'react';
import Constants from 'expo-constants';
import {
  Alert,
  NativeModules,
  ScrollView,
  StatusBar,
  StyleSheet,
  Switch,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';
import {
  InAppDebugBoundary,
  InAppDebugController,
  InAppDebugProvider,
  inAppDebug,
} from 'expo-inapp-debugger';
import { NativeRequestTrigger } from './modules/expo-native-request-trigger';

function DemoCrash({ shouldCrash }: { shouldCrash: boolean }) {
  if (shouldCrash) {
    throw new Error('示例页主动触发的渲染崩溃');
  }
  return null;
}

function extractHost(candidate?: string | null) {
  if (!candidate) {
    return null;
  }
  const trimmed = candidate.trim();
  if (!trimmed) {
    return null;
  }

  const withProtocol = /^[a-z]+:\/\//i.test(trimmed) ? trimmed : `http://${trimmed}`;
  try {
    const url = new URL(withProtocol);
    return url.hostname || null;
  } catch {
    const match = trimmed.match(/^([^/:]+)(?::\d+)?/);
    return match?.[1] || null;
  }
}

function isLoopbackHost(host?: string | null) {
  if (!host) {
    return false;
  }
  const normalized = host.toLowerCase();
  return normalized === '127.0.0.1' || normalized === 'localhost' || normalized === '0.0.0.0';
}

function isLoopbackUrl(url: string) {
  try {
    return isLoopbackHost(new URL(url).hostname);
  } catch {
    return false;
  }
}

function resolveDefaultWebSocketUrl() {
  const expoHost =
    extractHost(Constants.expoConfig?.hostUri) ??
    extractHost(Constants.expoGoConfig?.debuggerHost) ??
    extractHost(Constants.linkingUri);
  const scriptURL = NativeModules.SourceCode?.scriptURL as string | undefined;
  const scriptHost = extractHost(scriptURL);
  const host = expoHost ?? (!isLoopbackHost(scriptHost) ? scriptHost : null) ?? '127.0.0.1';
  return `ws://${host}:8787`;
}

function resolveDefaultHttpBaseUrl() {
  const expoHost =
    extractHost(Constants.expoConfig?.hostUri) ??
    extractHost(Constants.expoGoConfig?.debuggerHost) ??
    extractHost(Constants.linkingUri);
  const scriptURL = NativeModules.SourceCode?.scriptURL as string | undefined;
  const scriptHost = extractHost(scriptURL);
  const host = expoHost ?? (!isLoopbackHost(scriptHost) ? scriptHost : null) ?? '127.0.0.1';
  return `http://${host}:8788`;
}

function createDemoSocketPayload() {
  return JSON.stringify({
    type: 'client.demo',
    sentAt: new Date().toISOString(),
    random: Math.round(Math.random() * 10000),
    message: 'hello from expo-inapp-debugger example',
  });
}

function createDemoPostPayload() {
  return JSON.stringify(
    {
      orderId: `demo_${Date.now()}`,
      user: 'expo-debugger',
      items: [
        { sku: 'coffee-beans', quantity: 1 },
        { sku: 'dripper', quantity: 2 },
      ],
      note: 'POST request body from local demo screen',
      sentAt: new Date().toISOString(),
    },
    null,
    2
  );
}

function normalizeBaseUrl(candidate: string) {
  const trimmed = candidate.trim();
  if (!trimmed) {
    return null;
  }
  const withProtocol = /^[a-z]+:\/\//i.test(trimmed) ? trimmed : `http://${trimmed}`;
  return withProtocol.replace(/\/+$/, '');
}

function formatJSONText(text: string) {
  try {
    return JSON.stringify(JSON.parse(text), null, 2);
  } catch {
    return text;
  }
}

export default function App() {
  const [enabled, setEnabled] = React.useState(true);
  const [shouldCrash, setShouldCrash] = React.useState(false);
  const [httpBaseUrl, setHttpBaseUrl] = React.useState(() => resolveDefaultHttpBaseUrl());
  const [httpStatus, setHttpStatus] = React.useState('idle');
  const [httpBody, setHttpBody] = React.useState(() => createDemoPostPayload());
  const [httpResponsePreview, setHttpResponsePreview] = React.useState(
    '点击下面的 JS / 原生 GET / POST 按钮后，这里会显示最近一次响应体或原生请求说明。'
  );
  const [httpEvents, setHttpEvents] = React.useState<string[]>([]);
  const [httpHint, setHttpHint] = React.useState(() =>
    isLoopbackUrl(resolveDefaultHttpBaseUrl())
      ? '当前是 loopback 地址。模拟器可用，真机请改成电脑局域网 IP，例如 http://192.168.x.x:8788。'
      : '默认地址已按 Expo/Metro 宿主机自动推断。'
  );
  const [socketUrl, setSocketUrl] = React.useState(() => resolveDefaultWebSocketUrl());
  const [socketStatus, setSocketStatus] = React.useState('idle');
  const [socketMessage, setSocketMessage] = React.useState(() => createDemoSocketPayload());
  const [socketEvents, setSocketEvents] = React.useState<string[]>([]);
  const [socketHint, setSocketHint] = React.useState(() =>
    isLoopbackUrl(resolveDefaultWebSocketUrl())
      ? '当前是 loopback 地址。模拟器可用，真机请改成电脑局域网 IP，例如 ws://192.168.x.x:8787。'
      : '默认地址已按 Expo/Metro 宿主机自动推断。'
  );
  const socketRef = React.useRef<WebSocket | null>(null);

  const appendSocketEvent = React.useCallback((message: string) => {
    setSocketEvents((current) => [
      `${new Date().toLocaleTimeString('zh-CN', { hour12: false })} ${message}`,
      ...current,
    ].slice(0, 8));
  }, []);

  const appendHttpEvent = React.useCallback((message: string) => {
    setHttpEvents((current) => [
      `${new Date().toLocaleTimeString('zh-CN', { hour12: false })} ${message}`,
      ...current,
    ].slice(0, 8));
  }, []);

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

  const runLocalFetchGet = React.useCallback(async () => {
    const baseUrl = normalizeBaseUrl(httpBaseUrl);
    if (!baseUrl) {
      Alert.alert('HTTP 地址不能为空', '请先输入本地 mock server 地址。');
      return;
    }

    const requestUrl = `${baseUrl}/debug-http/get?channel=fetch&demo=get&at=${Date.now()}`;
    setHttpStatus('fetching');
    appendHttpEvent(`GET ${requestUrl}`);
    if (isLoopbackUrl(requestUrl)) {
      setHttpHint('如果你现在连的是 iPhone 真机，127.0.0.1 指向手机自己。请改成电脑局域网 IP。');
    } else {
      setHttpHint('正在请求本地 GET 接口...');
    }

    try {
      const response = await fetch(requestUrl, {
        method: 'GET',
        headers: {
          Accept: 'application/json',
          'X-Debug-Demo': 'fetch-get',
        },
      });
      const text = await response.text();
      const formatted = formatJSONText(text);
      setHttpStatus(`GET ${response.status}`);
      setHttpResponsePreview(formatted);
      setHttpHint('本地 GET 已完成。现在去 network 面板里看这条 fetch 记录的响应体。');
      appendHttpEvent(`GET ${response.status}`);
      console.info('本地 GET 响应', {
        status: response.status,
        url: requestUrl,
        body: formatted,
      });
    } catch (error) {
      setHttpStatus('get error');
      setHttpResponsePreview(String(error));
      if (isLoopbackUrl(requestUrl)) {
        setHttpHint('GET 失败：真机不能用 127.0.0.1，请改成电脑局域网 IP，并先启动 `pnpm http:mock`。');
      } else {
        setHttpHint('GET 失败，请确认 `pnpm http:mock` 正在运行，并且手机和电脑在同一网络。');
      }
      appendHttpEvent('GET error');
      console.error('本地 GET 失败', error);
    }
  }, [appendHttpEvent, httpBaseUrl]);

  const runLocalXhrPost = React.useCallback(async () => {
    const baseUrl = normalizeBaseUrl(httpBaseUrl);
    if (!baseUrl) {
      Alert.alert('HTTP 地址不能为空', '请先输入本地 mock server 地址。');
      return;
    }

    const requestUrl = `${baseUrl}/debug-http/post?channel=xhr&demo=post&at=${Date.now()}`;
    const requestBody = httpBody.trim() || createDemoPostPayload();
    setHttpStatus('posting');
    appendHttpEvent(`POST ${requestUrl}`);
    if (isLoopbackUrl(requestUrl)) {
      setHttpHint('如果你现在连的是 iPhone 真机，127.0.0.1 指向手机自己。请改成电脑局域网 IP。');
    } else {
      setHttpHint('正在请求本地 POST 接口...');
    }

    try {
      const result = await new Promise<{ status: number; body: string }>((resolve, reject) => {
        const xhr = new XMLHttpRequest();
        xhr.open('POST', requestUrl, true);
        xhr.setRequestHeader('Content-Type', 'application/json; charset=utf-8');
        xhr.setRequestHeader('Accept', 'application/json');
        xhr.setRequestHeader('X-Debug-Demo', 'xhr-post');
        xhr.onreadystatechange = () => {
          if (xhr.readyState !== XMLHttpRequest.DONE) {
            return;
          }
          resolve({
            status: xhr.status,
            body: xhr.responseText,
          });
        };
        xhr.onerror = () => {
          reject(new Error('XMLHttpRequest network error'));
        };
        xhr.ontimeout = () => {
          reject(new Error('XMLHttpRequest timeout'));
        };
        xhr.send(requestBody);
      });

      const formatted = formatJSONText(result.body);
      setHttpStatus(`POST ${result.status}`);
      setHttpResponsePreview(formatted);
      setHttpBody(requestBody);
      setHttpHint('本地 POST 已完成。现在去 network 面板里看这条 XHR 的请求体和响应体。');
      appendHttpEvent(`POST ${result.status}`);
      console.info('本地 POST 响应', {
        status: result.status,
        url: requestUrl,
        requestBody,
        responseBody: formatted,
      });
    } catch (error) {
      setHttpStatus('post error');
      setHttpResponsePreview(String(error));
      if (isLoopbackUrl(requestUrl)) {
        setHttpHint('POST 失败：真机不能用 127.0.0.1，请改成电脑局域网 IP，并先启动 `pnpm http:mock`。');
      } else {
        setHttpHint('POST 失败，请确认 `pnpm http:mock` 正在运行，并且手机和电脑在同一网络。');
      }
      appendHttpEvent('POST error');
      console.error('本地 POST 失败', error);
    }
  }, [appendHttpEvent, httpBaseUrl, httpBody]);

  const queueNativeModuleRequest = React.useCallback(
    async (method: 'GET' | 'POST') => {
      const baseUrl = normalizeBaseUrl(httpBaseUrl);
      if (!baseUrl) {
        Alert.alert('HTTP 地址不能为空', '请先输入本地 mock server 地址。');
        return;
      }

      const requestUrl =
        method === 'GET'
          ? `${baseUrl}/debug-http/get?channel=native-module&demo=get&at=${Date.now()}`
          : `${baseUrl}/debug-http/post?channel=native-module&demo=post&at=${Date.now()}`;
      const requestBody = method === 'POST' ? httpBody.trim() || createDemoPostPayload() : undefined;

      setHttpStatus(method === 'GET' ? 'native get queued' : 'native post queued');
      appendHttpEvent(`Native ${method} queued ${requestUrl}`);
      if (isLoopbackUrl(requestUrl)) {
        setHttpHint('如果你现在连的是 iPhone 真机，127.0.0.1 指向手机自己。请改成电脑局域网 IP。');
      } else {
        setHttpHint('请求已经从 example 本地 Expo module 发出。现在去 network 面板里找 origin=native 的记录。');
      }

      try {
        await NativeRequestTrigger.sendHttpRequest({
          url: requestUrl,
          method,
          body: requestBody,
          headers: {
            Accept: 'application/json',
            'X-Debug-Demo': method === 'GET' ? 'native-module-get' : 'native-module-post',
            ...(method === 'POST'
              ? {
                  'Content-Type': 'application/json; charset=utf-8',
                }
              : {}),
          },
        });
        setHttpBody(requestBody ?? httpBody);
        setHttpResponsePreview(
          method === 'GET'
            ? '原生 GET 已从 example 本地 Expo module 发出。若抓包链路正常，network 面板里会出现一条 origin=native 的 GET 记录。'
            : '原生 POST 已从 example 本地 Expo module 发出。若抓包链路正常，network 面板里会出现一条 origin=native 的 POST 记录，请求体就是当前输入框里的 JSON。'
        );
        console.info('已从原生 Expo module 触发请求', {
          method,
          url: requestUrl,
          requestBody,
        });
      } catch (error) {
        setHttpStatus('native queue error');
        setHttpResponsePreview(String(error));
        setHttpHint('原生请求没有成功排队。通常是本地 Expo module 还没 autolink，重新构建 example 即可。');
        appendHttpEvent(`Native ${method} queue error`);
        console.error('原生 Expo module 请求排队失败', error);
      }
    },
    [appendHttpEvent, httpBaseUrl, httpBody]
  );

  const runNativeModuleGet = React.useCallback(() => {
    return queueNativeModuleRequest('GET');
  }, [queueNativeModuleRequest]);

  const runNativeModulePost = React.useCallback(() => {
    return queueNativeModuleRequest('POST');
  }, [queueNativeModuleRequest]);

  const connectSocket = React.useCallback(() => {
    socketRef.current?.close();
    setSocketStatus('connecting');
    appendSocketEvent(`connecting ${socketUrl}`);
    if (isLoopbackUrl(socketUrl)) {
      setSocketHint('如果你现在连的是 iPhone 真机，127.0.0.1 指向手机自己。请改成电脑局域网 IP。');
    } else {
      setSocketHint('正在连接本地 echo server...');
    }

    const socket = new WebSocket(socketUrl);
    socketRef.current = socket;

    socket.onopen = () => {
      setSocketStatus('open');
      setSocketHint('连接成功，现在可以反复发送消息并在 network 面板里看完整收发。');
      console.info('WebSocket 已连接', socketUrl);
      appendSocketEvent('open');
      const initialPayload = createDemoSocketPayload();
      setSocketMessage(initialPayload);
      socket.send(initialPayload);
    };
    socket.onmessage = (event) => {
      console.info('WebSocket 消息', event.data);
      appendSocketEvent(`message ${String(event.data).slice(0, 100)}`);
    };
    socket.onerror = (event) => {
      console.error('WebSocket 错误', event);
      setSocketStatus('error');
      if (isLoopbackUrl(socketUrl)) {
        setSocketHint('连接失败：真机不能使用 127.0.0.1。请把地址改成你电脑的局域网 IP。');
      } else {
        setSocketHint('连接失败，请确认 `pnpm ws:echo` 正在运行，并且手机和电脑在同一网络。');
      }
      appendSocketEvent('error');
    };
    socket.onclose = (event) => {
      console.warn('WebSocket 已关闭', event.code, event.reason);
      setSocketStatus('closed');
      if (event.code === 1006 && isLoopbackUrl(socketUrl)) {
        setSocketHint('1006 + Connection refused 基本就是地址不对。真机请改成电脑局域网 IP。');
      }
      appendSocketEvent(`closed code=${event.code} reason=${event.reason || '-'}`);
    };
  }, [appendSocketEvent, socketUrl]);

  const sendSocketMessage = React.useCallback(() => {
    const socket = socketRef.current;
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      Alert.alert('WebSocket 未连接', '请先启动本地 echo server，再连接 WebSocket。');
      return;
    }

    const nextMessage = socketMessage.trim() || createDemoSocketPayload();
    socket.send(nextMessage);
    setSocketMessage(nextMessage);
    appendSocketEvent(`send ${nextMessage.slice(0, 100)}`);
  }, [appendSocketEvent, socketMessage]);

  const closeSocket = React.useCallback(() => {
    socketRef.current?.close(1000, 'manual close from demo');
    socketRef.current = null;
    setSocketStatus('closed');
    appendSocketEvent('manual close');
  }, [appendSocketEvent]);

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

            <View style={styles.socketCard}>
              <Text style={styles.cardTitle}>真实 WebSocket 回路</Text>
              <Text style={styles.cardHint}>
                先在 `example` 目录运行 `pnpm start:lan` 和 `pnpm ws:echo`，然后点击连接。真机如果仍然显示
                `127.0.0.1`，请把地址改成 `ws:echo` 启动日志里打印出来的局域网 URL。
              </Text>
              <Text style={styles.cardSubHint}>{socketHint}</Text>

              <View style={styles.socketStatusRow}>
                <Text style={styles.socketStatusLabel}>连接状态</Text>
                <View style={styles.socketStatusBadge}>
                  <Text style={styles.socketStatusBadgeText}>{socketStatus.toUpperCase()}</Text>
                </View>
              </View>

              <TextInput
                value={socketUrl}
                onChangeText={setSocketUrl}
                autoCapitalize="none"
                autoCorrect={false}
                placeholder="ws://192.168.x.x:8787"
                placeholderTextColor="#8E7F6C"
                style={styles.input}
              />

              <TextInput
                value={socketMessage}
                onChangeText={setSocketMessage}
                autoCapitalize="none"
                autoCorrect={false}
                multiline
                placeholder="输入要发送的消息"
                placeholderTextColor="#8E7F6C"
                style={[styles.input, styles.messageInput]}
              />

              <View style={styles.socketActionGrid}>
                <ActionButton label="连接 WebSocket" onPress={connectSocket} />
                <ActionButton label="发送消息" onPress={sendSocketMessage} />
                <ActionButton label="关闭连接" onPress={closeSocket} tone="secondary" />
              </View>

              <View style={styles.eventList}>
                {socketEvents.length === 0 ? (
                  <Text style={styles.eventPlaceholder}>连接、收发、关闭事件会显示在这里。</Text>
                ) : (
                  socketEvents.map((event) => (
                    <Text key={event} style={styles.eventItem}>
                      {event}
                    </Text>
                  ))
                )}
              </View>
            </View>

            <View style={styles.socketCard}>
              <Text style={styles.cardTitle}>本地 HTTP 回路</Text>
              <Text style={styles.cardHint}>
                先在 `example` 目录运行 `pnpm http:mock`。前两个按钮分别走 JS 的 `fetch` / `XMLHttpRequest`；
                后两个按钮会调用 example 本地 Expo module，从原生层直接发 GET / POST。Android 这条路径会用
                app 自建 `OkHttpClient` 加 `InAppDebuggerOkHttpIntegration`，专门用来验证 native 抓包。
              </Text>
              <Text style={styles.cardSubHint}>{httpHint}</Text>

              <View style={styles.socketStatusRow}>
                <Text style={styles.socketStatusLabel}>最近状态</Text>
                <View style={styles.socketStatusBadge}>
                  <Text style={styles.socketStatusBadgeText}>{httpStatus.toUpperCase()}</Text>
                </View>
              </View>

              <TextInput
                value={httpBaseUrl}
                onChangeText={setHttpBaseUrl}
                autoCapitalize="none"
                autoCorrect={false}
                placeholder="http://192.168.x.x:8788"
                placeholderTextColor="#8E7F6C"
                style={styles.input}
              />

              <TextInput
                value={httpBody}
                onChangeText={setHttpBody}
                autoCapitalize="none"
                autoCorrect={false}
                multiline
                placeholder="输入 POST 请求体"
                placeholderTextColor="#8E7F6C"
                style={[styles.input, styles.messageInput]}
              />

              <View style={styles.socketActionGrid}>
                <ActionButton label="本地 GET(fetch)" onPress={runLocalFetchGet} />
                <ActionButton label="本地 POST(XHR)" onPress={runLocalXhrPost} />
                <ActionButton label="原生 GET(Expo)" onPress={runNativeModuleGet} />
                <ActionButton label="原生 POST(Expo)" onPress={runNativeModulePost} />
                <ActionButton
                  label="重置 POST 请求体"
                  onPress={() => setHttpBody(createDemoPostPayload())}
                  tone="secondary"
                />
              </View>

              <View style={styles.eventList}>
                <Text style={styles.eventTitle}>最近响应体</Text>
                <Text style={styles.eventResponse}>{httpResponsePreview}</Text>
              </View>

              <View style={styles.eventList}>
                <Text style={styles.eventTitle}>最近 HTTP 事件</Text>
                {httpEvents.length === 0 ? (
                  <Text style={styles.eventPlaceholder}>GET / POST 触发记录会显示在这里。</Text>
                ) : (
                  httpEvents.map((event) => (
                    <Text key={event} style={styles.eventItem}>
                      {event}
                    </Text>
                  ))
                )}
              </View>
            </View>

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
  socketCard: {
    borderRadius: 18,
    padding: 16,
    backgroundColor: '#FFFDF8',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: '#D8D0C3',
    gap: 12,
  },
  cardTitle: {
    fontSize: 18,
    fontWeight: '800',
    color: '#2B221B',
  },
  cardHint: {
    fontSize: 14,
    lineHeight: 21,
    color: '#66584A',
  },
  cardSubHint: {
    fontSize: 13,
    lineHeight: 20,
    color: '#8A5631',
    backgroundColor: '#F8E8DA',
    borderRadius: 12,
    paddingHorizontal: 12,
    paddingVertical: 10,
  },
  socketStatusRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 12,
  },
  socketStatusLabel: {
    fontSize: 14,
    fontWeight: '700',
    color: '#2B221B',
  },
  socketStatusBadge: {
    paddingHorizontal: 10,
    paddingVertical: 6,
    borderRadius: 999,
    backgroundColor: '#E6DED1',
  },
  socketStatusBadgeText: {
    fontSize: 12,
    fontWeight: '800',
    color: '#2B221B',
  },
  input: {
    minHeight: 48,
    borderRadius: 14,
    borderWidth: 1,
    borderColor: '#D8D0C3',
    backgroundColor: '#FFFFFF',
    paddingHorizontal: 14,
    paddingVertical: 12,
    color: '#2B221B',
    fontSize: 15,
  },
  messageInput: {
    minHeight: 110,
    textAlignVertical: 'top',
    fontFamily: 'Menlo',
  },
  socketActionGrid: {
    gap: 10,
  },
  eventList: {
    borderRadius: 14,
    backgroundColor: '#2B221B',
    padding: 12,
    gap: 8,
  },
  eventPlaceholder: {
    color: '#E6DED1',
    fontSize: 13,
    lineHeight: 19,
  },
  eventTitle: {
    color: '#F2E7D7',
    fontSize: 13,
    fontWeight: '700',
  },
  eventResponse: {
    color: '#F6F1E8',
    fontSize: 12,
    lineHeight: 18,
    fontFamily: 'Menlo',
  },
  eventItem: {
    color: '#F6F1E8',
    fontSize: 12,
    lineHeight: 18,
    fontFamily: 'Menlo',
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
