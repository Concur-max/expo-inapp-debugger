import type { DebugNetworkEntry } from '../types';
import { formatDebugValue } from './preview';

type HeaderMap = Record<string, string>;
type RawHeaderMap = HeaderMap | string | null | undefined;

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
  nextTimelineSequence?: () => number;
  onInternalWarning?: (message: string, error?: unknown) => void;
  onDiagnostic?: (component: string, message: string) => void;
};

const MAX_WEBSOCKET_MESSAGE_HISTORY = 100;
const MAX_WEBSOCKET_MESSAGE_PREVIEW_LENGTH = 4_000;

class CappedStringBuffer {
  private readonly storage: Array<string | undefined>;
  private head = 0;
  private count = 0;

  constructor(capacity: number) {
    this.storage = new Array(Math.max(0, capacity));
  }

  append(value: string) {
    if (this.storage.length === 0) {
      return;
    }

    if (this.count < this.storage.length) {
      this.storage[(this.head + this.count) % this.storage.length] = value;
      this.count += 1;
      return;
    }

    this.storage[this.head] = value;
    this.head = (this.head + 1) % this.storage.length;
  }

  join(separator: string) {
    if (this.count === 0) {
      return '';
    }

    const parts = new Array<string>(this.count);
    for (let index = 0; index < this.count; index += 1) {
      parts[index] = this.storage[(this.head + index) % this.storage.length] ?? '';
    }
    return parts.join(separator);
  }
}

type MutableNetworkEntry = DebugNetworkEntry & {
  messagesBuffer?: CappedStringBuffer;
  messagesDirty?: boolean;
};

type XHRShell = {
  _index?: number;
  responseHeaders?: HeaderMap;
};

type BlobLike = {
  data?: {
    blobId?: string;
    offset?: number;
    size?: number;
  };
  _data?: {
    blobId?: string;
    offset?: number;
    size?: number;
  };
};

function now() {
  return Date.now();
}

function safeHttpBodyPreview(value: unknown) {
  if (typeof value === 'string') {
    return value;
  }

  return formatDebugValue(value, {
    maxLength: Number.MAX_SAFE_INTEGER,
    maxStringLength: Number.MAX_SAFE_INTEGER,
    maxObjectKeys: Number.MAX_SAFE_INTEGER,
    maxArrayItems: Number.MAX_SAFE_INTEGER,
    maxDepth: 32,
  });
}

function isBlobLike(value: unknown): value is BlobLike {
  if (typeof value !== 'object' || value == null) {
    return false;
  }

  const candidate = value as BlobLike;
  const data = candidate.data ?? candidate._data;
  return typeof data?.blobId === 'string' && typeof data.size === 'number';
}

function shouldReadBlobResponseAsText(contentType: string | undefined, responseType: string) {
  const normalizedContentType = contentType?.toLowerCase() ?? '';
  return (
    responseType === 'blob' &&
    (normalizedContentType.includes('json') ||
      normalizedContentType.startsWith('text/') ||
      normalizedContentType.includes('xml') ||
      normalizedContentType.includes('javascript'))
  );
}

function readBlobAsText(blob: BlobLike): Promise<string> {
  const FileReaderCtor = (globalThis as { FileReader?: new () => any }).FileReader;
  if (!FileReaderCtor) {
    return Promise.reject(new Error('FileReader is not available'));
  }

  return new Promise((resolve, reject) => {
    const reader = new FileReaderCtor();
    reader.onload = () => {
      resolve(typeof reader.result === 'string' ? reader.result : String(reader.result ?? ''));
    };
    reader.onerror = () => {
      reject(reader.error ?? new Error('Failed to read Blob response body'));
    };
    reader.onabort = () => {
      reject(new Error('Blob response body read was aborted'));
    };
    reader.readAsText(blob);
  });
}

function safeWebSocketPreview(value: unknown) {
  return formatDebugValue(value, {
    maxLength: MAX_WEBSOCKET_MESSAGE_PREVIEW_LENGTH,
  });
}

let cachedXHRInterceptor: XHRInterceptorModule | null | undefined;
let cachedWebSocketInterceptor: WebSocketInterceptorModule | null | undefined;

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

export class NetworkCollector {
  private readonly requests = new Map<string, MutableNetworkEntry>();
  private readonly xhrIdMap = new Map<number, string>();
  private readonly requestToXHRId = new Map<string, number>();
  private nextId = 1;
  private nextFallbackTimelineSequence = 1;
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
    this.options.onDiagnostic?.('JSNetwork', `enable maxRequests=${this.options.maxRequests}`);
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
      this.options.onDiagnostic?.('JSNetwork', 'attachXHR missing interceptor');
      return;
    }
    this.options.onDiagnostic?.('JSNetwork', 'attachXHR interceptor resolved');

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
        timelineSequence: this.nextTimelineSequence(),
      };
      this.requests.set(requestId, entry);
      this.options.onDiagnostic?.('JSNetwork', `xhr open id=${requestId} method=${entry.method} url=${url}`);
      this.emit(entry);
    });

    this.xhrInterceptor.setRequestHeaderCallback?.((header: string, value: string, xhr: XHRShell) => {
      const entry = this.getXHRRequest(xhr);
      if (!entry) return;
      const timestamp = now();
      const requestHeaders = (entry.requestHeaders ?? {}) as HeaderMap;
      requestHeaders[header] = value;
      entry.requestHeaders = requestHeaders;
      entry.updatedAt = timestamp;
      this.emit(entry);
    });

    this.xhrInterceptor.setSendCallback?.((data: unknown, xhr: XHRShell) => {
      const entry = this.getXHRRequest(xhr);
      if (!entry) return;
      const timestamp = now();
      entry.requestBody = safeHttpBodyPreview(data);
      entry.startedAt = timestamp;
      entry.updatedAt = timestamp;
      entry.timelineSequence = this.nextTimelineSequence();
      this.emit(entry);
    });

    this.xhrInterceptor.setHeaderReceivedCallback?.(
      (responseContentType: string, responseSize: number, responseHeaders: RawHeaderMap, xhr: XHRShell) => {
        const entry = this.getXHRRequest(xhr);
        if (!entry) return;
        const timestamp = now();
        entry.responseContentType = responseContentType;
        entry.responseSize = responseSize;
        entry.responseHeaders = normalizeHeaderMap(responseHeaders);
        entry.updatedAt = timestamp;
        this.emit(entry);
      }
    );

    this.xhrInterceptor.setResponseCallback?.(
      (
        status: number,
        _configuredTimeoutMs: number,
        response: unknown,
        responseURL: string,
        responseType: string,
        xhr: XHRShell
      ) => {
        const entry = this.getXHRRequest(xhr);
        if (!entry) return;
        const endedAt = now();
        entry.status = status;
        entry.responseType = responseType;
        entry.url = responseURL || entry.url;
        entry.endedAt = endedAt;
        entry.durationMs = endedAt - entry.startedAt;
        entry.updatedAt = endedAt;
        entry.state = status === 0 || status >= 400 ? 'error' : 'success';
        if (status === 0) {
          entry.error = 'XMLHttpRequest failed';
        }
        this.options.onDiagnostic?.(
          'JSNetwork',
          `xhr complete id=${entry.id} status=${status} state=${entry.state} url=${entry.url}`
        );
        const shouldReadBlobAsText =
          isBlobLike(response) && shouldReadBlobResponseAsText(entry.responseContentType, responseType);
        if (!shouldReadBlobAsText) {
          entry.responseBody = safeHttpBodyPreview(response);
        }
        this.emit(entry);
        if (shouldReadBlobAsText) {
          readBlobAsText(response)
            .then((text) => {
              entry.responseBody = text;
              entry.updatedAt = now();
              this.emit(entry);
            })
            .catch((error) => {
              entry.responseBody = `[Blob response body unavailable: ${String(error)}]`;
              entry.updatedAt = now();
              this.emit(entry);
            });
        }
        this.releaseXHRRequest(entry.id);
      }
    );

    this.xhrInterceptor.enableInterception?.();
    this.options.onDiagnostic?.('JSNetwork', 'attachXHR enableInterception called');
  }

  private attachWebSocket() {
    this.webSocketInterceptor = resolveWebSocketInterceptor();
    if (!this.webSocketInterceptor) {
      this.options.onInternalWarning?.('WebSocket interceptor was not found');
      this.options.onDiagnostic?.('JSNetwork', 'attachWebSocket missing interceptor');
      return;
    }
    this.options.onDiagnostic?.('JSNetwork', 'attachWebSocket interceptor resolved');

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
          messagesBuffer: new CappedStringBuffer(MAX_WEBSOCKET_MESSAGE_HISTORY),
          messagesDirty: false,
          timelineSequence: this.nextTimelineSequence(),
        };
        this.requests.set(entry.id, entry);
        this.options.onDiagnostic?.('JSNetwork', `ws connect id=${entry.id} url=${url}`);
        this.emit(entry);
      }
    );

    this.webSocketInterceptor.setOnOpenCallback?.((socketId: number) => {
      const entry = this.requests.get(`ws_${socketId}`);
      if (!entry) return;
      const timestamp = now();
      entry.state = 'open';
      entry.updatedAt = timestamp;
      this.options.onDiagnostic?.('JSNetwork', `ws open id=${entry.id}`);
      this.emit(entry);
    });

    this.webSocketInterceptor.setSendCallback?.((data: unknown, socketId: number) => {
      this.appendMessage(socketId, 'out', data);
    });

    this.webSocketInterceptor.setOnMessageCallback?.((data: unknown, socketId: number) => {
      this.appendMessage(socketId, 'in', data);
    });

    this.webSocketInterceptor.setOnErrorCallback?.((payload: { message?: string }, socketId: number) => {
      const entry = this.requests.get(`ws_${socketId}`);
      if (!entry) return;
      const timestamp = now();
      entry.state = 'error';
      entry.error = payload?.message || 'WebSocket error';
      entry.updatedAt = timestamp;
      this.options.onDiagnostic?.(
        'JSNetwork',
        `ws error id=${entry.id} message=${entry.error ?? ''}`
      );
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
        this.options.onDiagnostic?.(
          'JSNetwork',
          `ws close id=${entry.id} state=${entry.state} code=${payload.code}`
        );
        this.emit(entry);
      }
    );

    this.webSocketInterceptor.enableInterception?.();
    this.options.onDiagnostic?.('JSNetwork', 'attachWebSocket enableInterception called');
  }

  private appendMessage(socketId: number, direction: 'in' | 'out', data: unknown) {
    const entry = this.requests.get(`ws_${socketId}`);
    if (!entry) return;
    const preview = safeWebSocketPreview(data);
    if (direction === 'in') {
      entry.messageCountIn = (entry.messageCountIn ?? 0) + 1;
      if (typeof data === 'string') {
        entry.bytesIn = (entry.bytesIn ?? 0) + data.length;
      }
    } else {
      entry.messageCountOut = (entry.messageCountOut ?? 0) + 1;
      if (typeof data === 'string') {
        entry.bytesOut = (entry.bytesOut ?? 0) + data.length;
      }
    }
    const messagesBuffer = entry.messagesBuffer ?? new CappedStringBuffer(MAX_WEBSOCKET_MESSAGE_HISTORY);
    messagesBuffer.append(`${direction === 'in' ? '<<' : '>>'} ${preview}`);
    entry.messagesBuffer = messagesBuffer;
    entry.messagesDirty = true;
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
    if (this.requests.size > this.options.maxRequests) {
      this.trim();
    }
    this.options.onEntry(entry);
  }

  private trim() {
    while (this.requests.size > this.options.maxRequests) {
      const oldestEntry = this.findOldestEntry();
      if (!oldestEntry) {
        return;
      }
      this.requests.delete(oldestEntry.id);
      this.releaseXHRRequest(oldestEntry.id);
    }
  }

  private nextTimelineSequence() {
    return this.options.nextTimelineSequence?.() ?? this.nextFallbackTimelineSequence++;
  }

  private findOldestEntry() {
    let candidate: MutableNetworkEntry | null = null;
    for (const entry of this.requests.values()) {
      if (!candidate) {
        candidate = entry;
        continue;
      }
      if (compareNetworkTimeline(entry, candidate) < 0) {
        candidate = entry;
      }
    }
    return candidate;
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

export function materializeNetworkEntry(entry: DebugNetworkEntry): DebugNetworkEntry {
  const mutableEntry = entry as MutableNetworkEntry;
  const messagesBuffer = mutableEntry.messagesBuffer;
  if (!messagesBuffer) {
    return entry;
  }

  if (mutableEntry.messagesDirty) {
    mutableEntry.messages = messagesBuffer.join('\n');
    mutableEntry.messagesDirty = false;
  }

  return mutableEntry;
}

function normalizeHeaderMap(headers: RawHeaderMap): HeaderMap {
  if (!headers) {
    return {};
  }

  if (typeof headers === 'string') {
    return parseRawResponseHeaders(headers);
  }

  const result: HeaderMap = {};
  for (const [key, value] of Object.entries(headers)) {
    result[key] = String(value);
  }
  return result;
}

function parseRawResponseHeaders(rawHeaders: string): HeaderMap {
  if (!rawHeaders) {
    return {};
  }

  const result: HeaderMap = {};
  const lines = rawHeaders.split(/\r?\n/);
  for (const line of lines) {
    if (!line) {
      continue;
    }
    const separatorIndex = line.indexOf(':');
    if (separatorIndex <= 0) {
      continue;
    }

    const key = line.slice(0, separatorIndex).trim();
    if (!key) {
      continue;
    }
    const value = line.slice(separatorIndex + 1).trim();
    const existingValue = result[key];
    result[key] = existingValue ? `${existingValue}, ${value}` : value;
  }
  return result;
}

function compareNetworkTimeline(lhs: DebugNetworkEntry, rhs: DebugNetworkEntry) {
  if (lhs.startedAt !== rhs.startedAt) {
    return lhs.startedAt - rhs.startedAt;
  }
  if ((lhs.timelineSequence ?? 0) !== (rhs.timelineSequence ?? 0)) {
    return (lhs.timelineSequence ?? 0) - (rhs.timelineSequence ?? 0);
  }
  return lhs.id.localeCompare(rhs.id);
}
