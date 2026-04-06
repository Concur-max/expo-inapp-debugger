import * as React from 'react';
import { Platform } from 'react-native';
import type { InAppDebugStrings, SupportedLocale } from '../types';

const enUS: InAppDebugStrings = {
  title: 'Debug Panel',
  logsTab: 'Logs',
  networkTab: 'Network',
  jsLogOrigin: 'JS',
  nativeLogOrigin: 'Native',
  close: 'Close',
  searchPlaceholder: 'Search logs...',
  clear: 'Clear',
  loading: 'Loading...',
  noLogs: 'No logs yet',
  noSearchResult: 'No matching logs found',
  noNetworkRequests: 'No network requests yet',
  networkLoading: 'Loading network panel...',
  networkUnavailable: 'Network panel unavailable',
  sortAsc: 'Time Asc',
  sortDesc: 'Time Desc',
  copySingleSuccess: 'Copied to clipboard',
  copyVisibleSuccess: 'Visible logs copied',
  copyFailed: 'Copy failed',
  copySingleA11y: 'Copy this log',
  copyVisibleA11y: 'Copy visible logs',
  requestDetails: 'Request Details',
  requestHeaders: 'Request Headers',
  responseHeaders: 'Response Headers',
  requestBody: 'Request Body',
  responseBody: 'Response Body',
  messages: 'Messages',
  duration: 'Duration',
  status: 'Status',
  method: 'Method',
  state: 'State',
  protocol: 'Protocol',
  noRequestBody: 'No request body',
  noResponseBody: 'No response body',
  noMessages: 'No messages',
  errorTitle: 'Something went wrong',
  errorRetry: 'Retry',
  errorDebugInfo: 'Debug info',
  unknownError: 'Unknown error',
};

const zhCN: InAppDebugStrings = {
  title: '调试面板',
  logsTab: '日志',
  networkTab: '网络',
  jsLogOrigin: 'JS',
  nativeLogOrigin: '原生',
  close: '关闭',
  searchPlaceholder: '搜索日志...',
  clear: '清空',
  loading: '加载中...',
  noLogs: '暂无日志',
  noSearchResult: '未找到匹配的日志',
  noNetworkRequests: '暂无网络请求',
  networkLoading: '正在加载网络面板...',
  networkUnavailable: '网络面板不可用',
  sortAsc: '时间升序',
  sortDesc: '时间倒序',
  copySingleSuccess: '已复制到剪贴板',
  copyVisibleSuccess: '已复制当前显示的日志',
  copyFailed: '复制失败',
  copySingleA11y: '复制该条日志',
  copyVisibleA11y: '复制当前显示的日志',
  requestDetails: '请求详情',
  requestHeaders: '请求头',
  responseHeaders: '响应头',
  requestBody: '请求体',
  responseBody: '响应体',
  messages: '消息',
  duration: '耗时',
  status: '状态码',
  method: '方法',
  state: '状态',
  protocol: '协议',
  noRequestBody: '无请求体',
  noResponseBody: '无响应体',
  noMessages: '暂无消息',
  errorTitle: '出错了',
  errorRetry: '重试',
  errorDebugInfo: '调试信息',
  unknownError: '未知错误',
};

const zhTW: InAppDebugStrings = {
  title: '調試面板',
  logsTab: '日誌',
  networkTab: '網路',
  jsLogOrigin: 'JS',
  nativeLogOrigin: '原生',
  close: '關閉',
  searchPlaceholder: '搜尋日誌...',
  clear: '清空',
  loading: '載入中...',
  noLogs: '暫無日誌',
  noSearchResult: '未找到符合的日誌',
  noNetworkRequests: '暫無網路請求',
  networkLoading: '正在載入網路面板...',
  networkUnavailable: '網路面板不可用',
  sortAsc: '時間升序',
  sortDesc: '時間倒序',
  copySingleSuccess: '已複製到剪貼簿',
  copyVisibleSuccess: '已複製目前顯示的日誌',
  copyFailed: '複製失敗',
  copySingleA11y: '複製這條日誌',
  copyVisibleA11y: '複製目前顯示的日誌',
  requestDetails: '請求詳情',
  requestHeaders: '請求標頭',
  responseHeaders: '回應標頭',
  requestBody: '請求內容',
  responseBody: '回應內容',
  messages: '訊息',
  duration: '耗時',
  status: '狀態碼',
  method: '方法',
  state: '狀態',
  protocol: '協議',
  noRequestBody: '無請求內容',
  noResponseBody: '無回應內容',
  noMessages: '暫無訊息',
  errorTitle: '出錯了',
  errorRetry: '重試',
  errorDebugInfo: '調試資訊',
  unknownError: '未知錯誤',
};

const ja: InAppDebugStrings = {
  title: 'デバッグパネル',
  logsTab: 'ログ',
  networkTab: '通信',
  jsLogOrigin: 'JS',
  nativeLogOrigin: 'Native',
  close: '閉じる',
  searchPlaceholder: 'ログを検索...',
  clear: 'クリア',
  loading: '読み込み中...',
  noLogs: 'ログはまだありません',
  noSearchResult: '一致するログが見つかりません',
  noNetworkRequests: '通信ログはまだありません',
  networkLoading: '通信パネルを読み込み中...',
  networkUnavailable: '通信パネルは利用できません',
  sortAsc: '時間昇順',
  sortDesc: '時間降順',
  copySingleSuccess: 'クリップボードにコピーしました',
  copyVisibleSuccess: '表示中のログをコピーしました',
  copyFailed: 'コピーに失敗しました',
  copySingleA11y: 'このログをコピー',
  copyVisibleA11y: '表示中のログをコピー',
  requestDetails: 'リクエスト詳細',
  requestHeaders: 'リクエストヘッダー',
  responseHeaders: 'レスポンスヘッダー',
  requestBody: 'リクエスト本文',
  responseBody: 'レスポンス本文',
  messages: 'メッセージ',
  duration: '所要時間',
  status: 'ステータス',
  method: 'メソッド',
  state: '状態',
  protocol: 'プロトコル',
  noRequestBody: 'リクエスト本文はありません',
  noResponseBody: 'レスポンス本文はありません',
  noMessages: 'メッセージはありません',
  errorTitle: '問題が発生しました',
  errorRetry: '再試行',
  errorDebugInfo: 'デバッグ情報',
  unknownError: '不明なエラー',
};

const LOCALE_TABLE: Record<Exclude<SupportedLocale, 'auto'>, InAppDebugStrings> = {
  'en-US': enUS,
  'zh-CN': zhCN,
  'zh-TW': zhTW,
  ja,
};

function detectLocale(): Exclude<SupportedLocale, 'auto'> {
  const raw =
    Intl.DateTimeFormat().resolvedOptions().locale ||
    (Platform.OS === 'ios' ? 'zh-CN' : 'zh-CN');

  if (raw.startsWith('zh-HK') || raw.startsWith('zh-TW')) {
    return 'zh-TW';
  }
  if (raw.startsWith('zh')) {
    return 'zh-CN';
  }
  if (raw.startsWith('ja')) {
    return 'ja';
  }
  return 'en-US';
}

export function resolveStrings(
  locale: SupportedLocale | undefined,
  override: Partial<InAppDebugStrings> | undefined
): { locale: Exclude<SupportedLocale, 'auto'>; strings: InAppDebugStrings } {
  const resolvedLocale = locale === 'auto' || !locale ? detectLocale() : locale;
  const base = LOCALE_TABLE[resolvedLocale] ?? enUS;
  return {
    locale: resolvedLocale,
    strings: {
      ...base,
      ...override,
    },
  };
}

export const defaultStrings = zhCN;
export const InAppDebugStringsContext = React.createContext<InAppDebugStrings>(defaultStrings);
