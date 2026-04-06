import type { DebugNetworkEntry } from '../types';

type HeaderMap = Record<string, string>;

type XHRInterceptorModule = {
  isInterceptorEnabled?: () => boolean;
  setOpenCallback?: (...props: any[]) => void;
  setRequestHeaderCallback?: (...props: any[]) => void;
  setSendCallback?: (...props: any[]) => void;
  setHeaderReceivedCallback?: (...props: any[]) => void;
  setResponseCallback?: (...props: any[]) => void;
  enableInterception?: () => void;
  disableInterception?: () => void;
};

type WebSocketInterceptorModule = {
  isInterceptorEnabled?: () => boolean;
  setConnectCallback?: (...props: any[]) => void;
  setSendCallback?: (...props: any[]) => void;
  setCloseCallback?: (...props: any[]) => void;
  setOnOpenCallback?: (...props: any[]) => void;
  setOnMessageCallback?: (...props: any[]) => void;
  setOnErrorCallback?: (...props: any[]) => void;
  setOnCloseCallback?: (...props: any[]) => void;
  enableInterception?: () => void;
  disableInterception?: () => void;
};

type NetworkCollectorOptions = {
  maxRequests: number;
  onEntry: (entry: DebugNetworkEntry) => void;
  onInternalWarning?: (message: string, error?: unknown) => void;
};

type MutableNetworkEntry = DebugNetworkEntry & {
  messagesList?: string[];
};

type XHRShell = {
  _index?: number;
  responseHeaders?: HeaderMap;
};

function now() {
  return Date.now();
}

function safeStringify(value: unknown) {
  if (typeof value === 'string') {
    return value;
  }
  if (value == null) {
    return '';
  }
  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}

function tryRequire<T>(ids: string[]): T | null {
  for (const id of ids) {
    try {
      const mod = require(id);
      return (mod.default ?? mod) as T;
    } catch {
      continue;
    }
  }
  return null;
}

function resolveXHRInterceptor() {
  return tryRequire<XHRInterceptorModule>([
    'react-native/src/private/devsupport/devmenu/elementinspector/XHRInterceptor',
    'react-native/src/private/inspector/XHRInterceptor',
    'react-native/Libraries/Network/XHRInterceptor',
  ]);
}

function resolveWebSocketInterceptor() {
  return tryRequire<WebSocketInterceptorModule>([
    'react-native/Libraries/WebSocket/WebSocketInterceptor',
  ]);
}

export class NetworkCollector {
  private readonly requests = new Map<string, MutableNetworkEntry>();
  private readonly xhrIdMap = new Map<number, string>();
  private nextId = 1;
  private enabled = false;
  private xhrInterceptor: XHRInterceptorModule | null = null;
  private webSocketInterceptor: WebSocketInterceptorModule | null = null;

  constructor(private readonly options: NetworkCollectorOptions) {}

  updateOptions(options: Pick<NetworkCollectorOptions, 'maxRequests'>) {
    this.options.maxRequests = options.maxRequests;
    this.trim();
  }

  enable() {
    if (this.enabled) {
      return;
    }
    this.enabled = true;
    this.attachXHR();
    this.attachWebSocket();
  }

  disable() {
    if (!this.enabled) {
      return;
    }
    this.enabled = false;
    this.xhrInterceptor?.setOpenCallback?.(undefined);
    this.xhrInterceptor?.setRequestHeaderCallback?.(undefined);
    this.xhrInterceptor?.setSendCallback?.(undefined);
    this.xhrInterceptor?.setHeaderReceivedCallback?.(undefined);
    this.xhrInterceptor?.setResponseCallback?.(undefined);
    this.webSocketInterceptor?.setConnectCallback?.(undefined);
    this.webSocketInterceptor?.setSendCallback?.(undefined);
    this.webSocketInterceptor?.setCloseCallback?.(undefined);
    this.webSocketInterceptor?.setOnOpenCallback?.(undefined);
    this.webSocketInterceptor?.setOnMessageCallback?.(undefined);
    this.webSocketInterceptor?.setOnErrorCallback?.(undefined);
    this.webSocketInterceptor?.setOnCloseCallback?.(undefined);
  }

  private attachXHR() {
    this.xhrInterceptor = resolveXHRInterceptor();
    if (!this.xhrInterceptor) {
      this.options.onInternalWarning?.('XHR interceptor was not found');
      return;
    }

    this.xhrInterceptor.setOpenCallback?.((method: string, url: string, xhr: XHRShell) => {
      const interceptorId = this.nextId++
      const requestId = `http_${interceptorId}`;
      xhr._index = interceptorId;
      this.xhrIdMap.set(interceptorId, requestId);
      const entry: MutableNetworkEntry = {
        id: requestId,
        kind: 'http',
        method: method || 'GET',
        url,
        state: 'pending',
        startedAt: now(),
        updatedAt: now(),
        requestHeaders: {},
        responseHeaders: {},
      };
      this.requests.set(requestId, entry);
      this.emit(entry);
    });

    this.xhrInterceptor.setRequestHeaderCallback?.((header: string, value: string, xhr: XHRShell) => {
      const entry = this.getXHRRequest(xhr);
      if (!entry) return;
      entry.requestHeaders = {
        ...(entry.requestHeaders ?? {}),
        [header]: value,
      };
      entry.updatedAt = now();
      this.emit(entry);
    });

    this.xhrInterceptor.setSendCallback?.((data: unknown, xhr: XHRShell) => {
      const entry = this.getXHRRequest(xhr);
      if (!entry) return;
      entry.requestBody = safeStringify(data);
      entry.startedAt = now();
      entry.updatedAt = now();
      this.emit(entry);
    });

    this.xhrInterceptor.setHeaderReceivedCallback?.(
      (
        responseContentType: string,
        responseSize: number,
        responseHeaders: HeaderMap,
        xhr: XHRShell
      ) => {
        const entry = this.getXHRRequest(xhr);
        if (!entry) return;
        entry.responseContentType = responseContentType;
        entry.responseSize = responseSize;
        entry.responseHeaders = responseHeaders;
        entry.updatedAt = now();
        this.emit(entry);
      }
    );

    this.xhrInterceptor.setResponseCallback?.(
      (
        status: number,
        timeout: number,
        response: unknown,
        responseURL: string,
        responseType: string,
        xhr: XHRShell
      ) => {
        const entry = this.getXHRRequest(xhr);
        if (!entry) return;
        const endedAt = now();
        entry.status = status;
        entry.responseBody = safeStringify(response);
        entry.responseType = responseType;
        entry.url = responseURL || entry.url;
        entry.endedAt = endedAt;
        entry.durationMs = endedAt - entry.startedAt;
        entry.updatedAt = endedAt;
        entry.state = timeout ? 'error' : status >= 400 ? 'error' : 'success';
        if (timeout) {
          entry.error = `timeout=${timeout}`;
        }
        this.emit(entry);
      }
    );

    this.xhrInterceptor.enableInterception?.();
  }

  private attachWebSocket() {
    this.webSocketInterceptor = resolveWebSocketInterceptor();
    if (!this.webSocketInterceptor) {
      this.options.onInternalWarning?.('WebSocket interceptor was not found');
      return;
    }

    this.webSocketInterceptor.setConnectCallback?.(
      (url: string, protocols: string[] | null, _options: unknown, socketId: number) => {
        const entry: MutableNetworkEntry = {
          id: `ws_${socketId}`,
          kind: 'websocket',
          method: 'WS',
          url,
          protocol: protocols?.join(', ') || '',
          state: 'pending',
          startedAt: now(),
          updatedAt: now(),
          messages: '',
          messagesList: [],
        };
        this.requests.set(entry.id, entry);
        this.emit(entry);
      }
    );

    this.webSocketInterceptor.setOnOpenCallback?.((socketId: number) => {
      const entry = this.requests.get(`ws_${socketId}`);
      if (!entry) return;
      entry.state = 'success';
      entry.updatedAt = now();
      this.emit(entry);
    });

    this.webSocketInterceptor.setSendCallback?.((data: unknown, socketId: number) => {
      this.appendMessage(socketId, `>> ${safeStringify(data)}`);
    });

    this.webSocketInterceptor.setOnMessageCallback?.((data: unknown, socketId: number) => {
      this.appendMessage(socketId, `<< ${safeStringify(data)}`);
    });

    this.webSocketInterceptor.setOnErrorCallback?.((payload: { message?: string }, socketId: number) => {
      const entry = this.requests.get(`ws_${socketId}`);
      if (!entry) return;
      entry.state = 'error';
      entry.error = payload?.message || 'WebSocket error';
      entry.updatedAt = now();
      this.emit(entry);
    });

    this.webSocketInterceptor.setCloseCallback?.((code: number | null, reason: string | null, socketId: number) => {
      const entry = this.requests.get(`ws_${socketId}`);
      if (!entry) return;
      const endedAt = now();
      entry.state = entry.error ? 'error' : 'closed';
      entry.closeReason = [code, reason].filter(Boolean).join(' ');
      entry.endedAt = endedAt;
      entry.durationMs = endedAt - entry.startedAt;
      entry.updatedAt = endedAt;
      this.emit(entry);
    });

    this.webSocketInterceptor.enableInterception?.();
  }

  private appendMessage(socketId: number, message: string) {
    const entry = this.requests.get(`ws_${socketId}`);
    if (!entry) return;
    entry.messagesList = [...(entry.messagesList ?? []), message].slice(-100);
    entry.messages = entry.messagesList.join('\n');
    entry.updatedAt = now();
    this.emit(entry);
  }

  private getXHRRequest(xhr: XHRShell) {
    const xhrId = xhr._index;
    if (xhrId == null) {
      return null;
    }
    const requestId = this.xhrIdMap.get(xhrId);
    if (!requestId) {
      return null;
    }
    return this.requests.get(requestId) ?? null;
  }

  private emit(entry: MutableNetworkEntry) {
    this.trim();
    const { messagesList: _messagesList, ...safeEntry } = entry;
    this.options.onEntry({
      ...safeEntry,
    });
  }

  private trim() {
    while (this.requests.size > this.options.maxRequests) {
      const firstKey = this.requests.keys().next().value;
      if (!firstKey) {
        return;
      }
      this.requests.delete(firstKey);
    }
  }
}
