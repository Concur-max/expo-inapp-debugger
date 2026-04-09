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

let cachedXHRInterceptor: XHRInterceptorModule | null | undefined;
let cachedWebSocketInterceptor: WebSocketInterceptorModule | null | undefined;
let cachedUseNativeWebSocketCapture: boolean | undefined;

function resolveXHRInterceptor() {
  if (cachedXHRInterceptor !== undefined) {
    return cachedXHRInterceptor;
  }
  try {
    const mod = require('react-native/src/private/devsupport/devmenu/elementinspector/XHRInterceptor');
    cachedXHRInterceptor = (mod.default ?? mod) as XHRInterceptorModule;
  } catch {
    cachedXHRInterceptor = null;
  }
  return cachedXHRInterceptor;
}

function resolveWebSocketInterceptor() {
  if (cachedWebSocketInterceptor !== undefined) {
    return cachedWebSocketInterceptor;
  }
  try {
    const mod = require('react-native/Libraries/WebSocket/WebSocketInterceptor');
    cachedWebSocketInterceptor = (mod.default ?? mod) as WebSocketInterceptorModule;
  } catch {
    cachedWebSocketInterceptor = null;
  }
  return cachedWebSocketInterceptor;
}

function shouldUseNativeWebSocketCapture() {
  if (cachedUseNativeWebSocketCapture !== undefined) {
    return cachedUseNativeWebSocketCapture;
  }
  try {
    const reactNative = require('react-native');
    cachedUseNativeWebSocketCapture = reactNative.Platform?.OS === 'ios';
  } catch {
    cachedUseNativeWebSocketCapture = false;
  }
  return cachedUseNativeWebSocketCapture;
}

export class NetworkCollector {
  private readonly requests = new Map<string, MutableNetworkEntry>();
  private readonly xhrIdMap = new Map<number, string>();
  private readonly requestToXHRId = new Map<string, number>();
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
    this.xhrInterceptor?.disableInterception?.();
    this.webSocketInterceptor?.disableInterception?.();
    this.requests.clear();
    this.xhrIdMap.clear();
    this.requestToXHRId.clear();
  }

  private attachXHR() {
    this.xhrInterceptor = resolveXHRInterceptor();
    if (!this.xhrInterceptor) {
      this.options.onInternalWarning?.('XHR interceptor was not found');
      return;
    }

    this.xhrInterceptor.setOpenCallback?.((method: string, url: string, xhr: XHRShell) => {
      const interceptorId = this.nextId++;
      const timestamp = now();
      const requestId = `http_${interceptorId}`;
      xhr._index = interceptorId;
      this.xhrIdMap.set(interceptorId, requestId);
      this.requestToXHRId.set(requestId, interceptorId);
      const entry: MutableNetworkEntry = {
        id: requestId,
        kind: 'http',
        method: method || 'GET',
        url,
        origin: 'js',
        state: 'pending',
        startedAt: timestamp,
        updatedAt: timestamp,
        requestHeaders: {},
        responseHeaders: {},
      };
      this.requests.set(requestId, entry);
      this.emit(entry);
    });

    this.xhrInterceptor.setRequestHeaderCallback?.((header: string, value: string, xhr: XHRShell) => {
      const entry = this.getXHRRequest(xhr);
      if (!entry) return;
      const timestamp = now();
      entry.requestHeaders = {
        ...(entry.requestHeaders ?? {}),
        [header]: value,
      };
      entry.updatedAt = timestamp;
      this.emit(entry);
    });

    this.xhrInterceptor.setSendCallback?.((data: unknown, xhr: XHRShell) => {
      const entry = this.getXHRRequest(xhr);
      if (!entry) return;
      const timestamp = now();
      entry.requestBody = safeStringify(data);
      entry.startedAt = timestamp;
      entry.updatedAt = timestamp;
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
        const timestamp = now();
        entry.responseContentType = responseContentType;
        entry.responseSize = responseSize;
        entry.responseHeaders = responseHeaders;
        entry.updatedAt = timestamp;
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
        this.releaseXHRRequest(entry.id);
      }
    );

    this.xhrInterceptor.enableInterception?.();
  }

  private attachWebSocket() {
    if (shouldUseNativeWebSocketCapture()) {
      return;
    }

    this.webSocketInterceptor = resolveWebSocketInterceptor();
    if (!this.webSocketInterceptor) {
      this.options.onInternalWarning?.('WebSocket interceptor was not found');
      return;
    }

    this.webSocketInterceptor.setConnectCallback?.(
      (url: string, protocols: string[] | null, _options: unknown, socketId: number) => {
        const timestamp = now();
        const entry: MutableNetworkEntry = {
          id: `ws_${socketId}`,
          kind: 'websocket',
          method: 'WS',
          url,
          origin: 'js',
          protocol: protocols?.join(', ') || '',
          state: 'connecting',
          startedAt: timestamp,
          updatedAt: timestamp,
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
      const timestamp = now();
      entry.state = 'open';
      entry.updatedAt = timestamp;
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
      const timestamp = now();
      entry.state = 'error';
      entry.error = payload?.message || 'WebSocket error';
      entry.updatedAt = timestamp;
      this.emit(entry);
    });

    this.webSocketInterceptor.setCloseCallback?.((code: number | null, reason: string | null, socketId: number) => {
      const entry = this.requests.get(`ws_${socketId}`);
      if (!entry) return;
      const timestamp = now();
      entry.state = entry.error ? 'error' : 'closing';
      entry.requestedCloseCode = code ?? undefined;
      entry.requestedCloseReason = reason ?? undefined;
      entry.updatedAt = timestamp;
      this.emit(entry);
    });

    this.webSocketInterceptor.setOnCloseCallback?.(
      (payload: { code: number; reason?: string | null }, socketId: number) => {
        const entry = this.requests.get(`ws_${socketId}`);
        if (!entry) return;
        const endedAt = now();
        entry.state = entry.error ? 'error' : 'closed';
        entry.closeCode = payload.code;
        entry.closeReason = payload.reason ?? undefined;
        entry.endedAt = endedAt;
        entry.durationMs = endedAt - entry.startedAt;
        entry.updatedAt = endedAt;
        this.emit(entry);
      }
    );

    this.webSocketInterceptor.enableInterception?.();
  }

  private appendMessage(socketId: number, message: string) {
    const entry = this.requests.get(`ws_${socketId}`);
    if (!entry) return;
    const messagesList = entry.messagesList ?? [];
    messagesList.push(message);
    if (messagesList.length > 100) {
      messagesList.splice(0, messagesList.length - 100);
    }
    entry.messagesList = messagesList;
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
      this.releaseXHRRequest(firstKey);
    }
  }

  private releaseXHRRequest(requestId: string) {
    const xhrId = this.requestToXHRId.get(requestId);
    if (xhrId == null) {
      return;
    }
    this.requestToXHRId.delete(requestId);
    this.xhrIdMap.delete(xhrId);
  }
}
