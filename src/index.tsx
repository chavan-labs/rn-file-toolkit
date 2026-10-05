import { useState, useCallback, useRef, useEffect } from 'react';
import { NativeEventEmitter, NativeModules, Platform } from 'react-native';
import FileToolkitSpec from './NativeFileToolkit';

const LINKING_ERROR =
  `The native module for 'rn-file-toolkit' could not be found.\n\n` +
  Platform.select({
    ios: "• Run 'cd ios && pod install' (or 'npx pod-install') and rebuild the app.\n",
    android: '• Rebuild the app so the Android module is compiled in.\n',
    default: '',
  }) +
  '• Rebuild after installing — a JS-only reload (Fast Refresh) is not enough.\n' +
  '• This package contains native code, so it does not work in Expo Go. Use a development build.\n' +
  '• On web / Node (SSR, tests) the native module is unavailable; guard your calls or mock the module.';

const OLD_ARCH_ERROR =
  `'rn-file-toolkit' requires the React Native New Architecture, but this app runs the legacy bridge.\n\n` +
  '• Enable it (newArchEnabled=true in android/gradle.properties; RCT_NEW_ARCH_ENABLED=1 pod install on iOS) and rebuild.';

const _linkedModule: any = FileToolkitSpec ?? NativeModules.FileToolkit;
// On the legacy bridge the module is found, but iOS exports only a few of its
// methods there — so every other call would fail with "is not a function".
const _isLegacyBridge =
  _linkedModule != null && typeof _linkedModule.download !== 'function';

/**
 * The native module, or a proxy that throws an actionable error on first use.
 *
 * Importing this package must never throw on its own — bundlers, tests and SSR
 * all evaluate the module graph without a native runtime attached.
 */
const FileToolkitModule: any =
  _linkedModule != null && !_isLegacyBridge
    ? _linkedModule
    : new Proxy(
        {},
        {
          get() {
            throw new Error(_isLegacyBridge ? OLD_ARCH_ERROR : LINKING_ERROR);
          },
        }
      );

/** `true` when the native module is linked and usable on this platform. */
export const isAvailable: boolean = _linkedModule != null && !_isLegacyBridge;

type TerminalEventName = 'onDownloadComplete' | 'onDownloadError';
const TERMINAL_EVENTS: TerminalEventName[] = [
  'onDownloadComplete',
  'onDownloadError',
];
const MAX_UNHEARD_EVENTS = 100;
// ponytail: bounded to the most recent 500 ids; an older one is treated as
// unknown and its result buffered like a download from a previous launch.
const MAX_OWN_DOWNLOAD_IDS = 500;
/** Ids of downloads started in this JS session (insertion-ordered). */
const _ownDownloadIds = new Set<string>();
const _terminalSubscribers: Record<TerminalEventName, Set<(e: any) => void>> = {
  onDownloadComplete: new Set(),
  onDownloadError: new Set(),
};
const _unheardTerminalEvents: Record<TerminalEventName, any[]> = {
  onDownloadComplete: [],
  onDownloadError: [],
};

let _eventEmitter: NativeEventEmitter | null = null;
function getEventEmitter(): NativeEventEmitter {
  if (!_eventEmitter) {
    _eventEmitter = new NativeEventEmitter(FileToolkitModule);
    // Native holds background results only until *some* listener for the event
    // name exists, and cannot tell which name a removed listener belonged to.
    // This relay stays subscribed for the app's lifetime (registered first, so
    // it runs before per-download watchers) and buffers in JS instead, where
    // subscribers are counted exactly.
    for (const name of TERMINAL_EVENTS) {
      _eventEmitter.addListener(name, (event: any) =>
        _relayTerminalEvent(name, event)
      );
    }
  }
  return _eventEmitter;
}

function _relayTerminalEvent(name: TerminalEventName, event: any): void {
  const subscribers = _terminalSubscribers[name];
  if (subscribers.size > 0) {
    Array.from(subscribers).forEach((cb) => cb(event));
    return;
  }
  // A download started in this JS session reports through its own promise.
  if (event?.downloadId && _ownDownloadIds.has(event.downloadId)) return;
  // e.g. a download that finished while the app was closed — keep it until
  // the app subscribes.
  const unheard = _unheardTerminalEvents[name];
  unheard.push(event);
  if (unheard.length > MAX_UNHEARD_EVENTS) unheard.shift();
}

function _subscribeTerminalEvent(
  name: TerminalEventName,
  cb: (event: any) => void
): () => void {
  getEventEmitter();
  const subscribers = _terminalSubscribers[name];
  const entry = (event: any) => cb(event); // unique per subscription
  subscribers.add(entry);
  const pending = _unheardTerminalEvents[name].splice(0);
  if (pending.length > 0) {
    // Deliver after `subscribe` has returned its unsubscribe function.
    Promise.resolve().then(() => {
      for (const event of pending) {
        if (subscribers.has(entry)) entry(event);
        else _relayTerminalEvent(name, event);
      }
    });
  }
  return () => {
    subscribers.delete(entry);
  };
}

export interface ProgressInfo {
  /** 0–100, or -1 when the server did not send a Content-Length. */
  percent: number;
  bytesDownloaded: number;
  /** -1 when the server did not send a Content-Length. */
  totalBytes: number;
  speedBps: number;
  etaSeconds: number;
}

export interface DownloadOptions {
  url: string;
  fileName?: string;
  background?: boolean;
  headers?: Record<string, string>;
  destination?: 'downloads' | 'cache' | 'documents';
  /** Notification title shown during background download. @platform Android */
  notificationTitle?: string;
  /** Notification description shown during background download. @platform Android */
  notificationDescription?: string;
  checksum?: {
    hash: string;
    algorithm: 'md5' | 'sha1' | 'sha256';
  };
  onProgress?: (info: ProgressInfo) => void;
  queue?: boolean;
  downloadId?: string;
  priority?: 'high' | 'normal';
  retry?: {
    attempts: number;
    delay?: number;
    onRetry?: (attempt: number, error: string) => void;
  };
}

export interface UploadOptions {
  url: string;
  filePath: string;
  fieldName?: string;
  headers?: Record<string, string>;
  parameters?: Record<string, string>;
  onProgress?: (percent: number) => void;
  uploadId?: string;
}

export interface DownloadResult {
  success: boolean;
  filePath?: string;
  downloadId?: string;
  error?: string;
}

export interface UploadResult {
  success: boolean;
  status?: number;
  data?: string;
  error?: string;
  uploadId?: string;
}

export interface ActionResult {
  success: boolean;
  error?: string;
}

export interface CachedFile {
  fileName: string;
  filePath: string;
  size: number;
  modifiedAt: number;
}

export interface CacheResult {
  success: boolean;
  files?: CachedFile[];
  error?: string;
}

export interface SaveBase64Options {
  base64Data: string;
  fileName?: string;
  destination?: 'downloads' | 'cache' | 'documents';
}

export interface SaveBase64Result {
  success: boolean;
  filePath?: string;
  error?: string;
}

export interface UrlToBase64Options {
  url: string;
  headers?: Record<string, string>;
}

export interface UrlToBase64Result {
  success: boolean;
  base64?: string;
  mimeType?: string;
  dataUri?: string;
  error?: string;
}

export interface ShareFileOptions {
  filePath: string;
  title?: string;
  subject?: string;
}

export interface OpenFileOptions {
  filePath: string;
  mimeType?: string;
}

export interface ShareFileResult {
  success: boolean;
  completed?: boolean;
  error?: string;
}

export interface OpenFileResult {
  success: boolean;
  error?: string;
}

export type FsEncoding = 'utf8' | 'base64';

export interface FsStat {
  path: string;
  name: string;
  size: number;
  modified: number;
  isDir: boolean;
}

export interface DiskSpaceResult {
  success: boolean;
  freeBytes?: number;
  totalBytes?: number;
  error?: string;
}

export type HashAlgorithm = 'md5' | 'sha1' | 'sha256';

export interface HashResult {
  success: boolean;
  hash?: string;
  error?: string;
}

export interface Cookie {
  name: string;
  value: string;
  domain: string;
  path: string;
  expiresDate?: number;
  isSecure?: boolean;
  isHTTPOnly?: boolean;
}

export interface CookiesResult {
  success: boolean;
  cookies?: Cookie[];
  error?: string;
}

export interface MediaStoreOptions {
  filePath: string;
  mediaType?: 'image' | 'video' | 'audio' | 'download';
  album?: string;
}

export interface MediaStoreResult {
  success: boolean;
  uri?: string;
  error?: string;
}

export interface SessionApi {
  add: (sessionId: string, filePath: string) => void;
  get: (sessionId: string) => string[];
  clear: (sessionId: string) => Promise<ActionResult>;
  clearAll: () => Promise<ActionResult>;
}

export interface FsApi {
  exists: (filePath: string) => Promise<boolean>;
  stat: (filePath: string) => Promise<FsStat>;
  readFile: (filePath: string, encoding?: FsEncoding) => Promise<string>;
  writeFile: (
    filePath: string,
    data: string,
    encoding?: FsEncoding
  ) => Promise<void>;
  appendFile: (
    filePath: string,
    data: string,
    encoding?: FsEncoding
  ) => Promise<void>;
  copyFile: (fromPath: string, toPath: string) => Promise<void>;
  moveFile: (fromPath: string, toPath: string) => Promise<void>;
  deleteFile: (filePath: string) => Promise<void>;
  mkdir: (dirPath: string) => Promise<void>;
  ls: (dirPath: string) => Promise<string[]>;
  df: () => Promise<DiskSpaceResult>;
  hash: (filePath: string, algorithm?: HashAlgorithm) => Promise<HashResult>;
}

export interface QueueOptions {
  maxConcurrent?: number;
}

export interface QueueStatus {
  active: number;
  pending: number;
  maxConcurrent: number;
}

interface QueueItem {
  options: DownloadOptions & { downloadId: string };
  resolve: (run: RunningDownload) => void;
  reject: (reason?: any) => void;
}

/**
 * `result` is what the native `download()` call resolved with. `settled`
 * resolves with the final outcome — for a background download that is the
 * terminal `onDownloadComplete` / `onDownloadError` event (or a JS-side
 * cancel), which arrives long after `result`.
 */
interface RunningDownload {
  result: DownloadResult;
  settled: Promise<DownloadResult>;
}

function _cancelledResult(downloadId: string): DownloadResult {
  return { success: false, downloadId, error: 'CANCELLED' };
}

class DownloadQueue {
  private _maxConcurrent: number = 3;
  private _active: number = 0;
  private _queue: QueueItem[] = [];

  setOptions(opts: QueueOptions): void {
    if (opts.maxConcurrent != null && opts.maxConcurrent > 0) {
      this._maxConcurrent = opts.maxConcurrent;
      this._flush();
    }
  }

  getStatus(): QueueStatus {
    return {
      active: this._active,
      pending: this._queue.length,
      maxConcurrent: this._maxConcurrent,
    };
  }

  enqueue(options: DownloadOptions): Promise<RunningDownload> {
    return new Promise<RunningDownload>((resolve, reject) => {
      // Assign the id now so a still-queued download can be cancelled by it.
      const item: QueueItem = {
        options: {
          ...options,
          downloadId: options.downloadId || _generateId(),
        },
        resolve,
        reject,
      };
      if (options.priority === 'high') {
        this._queue.unshift(item);
      } else {
        this._queue.push(item);
      }
      this._flush();
    });
  }

  /** Removes a download that has not started yet. Returns `false` if not queued. */
  cancel(downloadId: string): boolean {
    const index = this._queue.findIndex(
      (item) => item.options.downloadId === downloadId
    );
    if (index === -1) return false;
    const [item] = this._queue.splice(index, 1);
    const cancelled = _cancelledResult(downloadId);
    item!.resolve({ result: cancelled, settled: Promise.resolve(cancelled) });
    return true;
  }

  private _flush(): void {
    while (this._active < this._maxConcurrent && this._queue.length > 0) {
      const item = this._queue.shift()!;
      this._active++;
      const nativeOptions = { ...item.options };
      delete nativeOptions.queue;
      delete nativeOptions.priority;
      // A background download resolves as soon as the OS accepts it, so hold
      // its slot until it actually finishes — otherwise maxConcurrent is moot.
      _runDownload(nativeOptions)
        .then(
          (run) => {
            item.resolve(run);
            return run.settled;
          },
          (err) => {
            item.reject(err);
          }
        )
        .finally(() => {
          this._active--;
          this._flush();
        });
    }
  }
}

const _globalQueue = new DownloadQueue();

/**
 * Accepts `file://` URIs (as returned by pickers, cameras and other libraries)
 * wherever a filesystem path is expected; native code only understands paths.
 */
function _path(p: string): string {
  if (typeof p !== 'string' || !p.startsWith('file://')) return p;
  const stripped = p.slice('file://'.length).replace(/^localhost(?=\/)/, '');
  try {
    return decodeURIComponent(stripped);
  } catch {
    return stripped; // not percent-encoded (e.g. a literal "%" in the name)
  }
}

function _generateId(): string {
  // Use crypto.getRandomValues (available on Hermes since RN 0.73) for collision resistance
  if (
    typeof globalThis.crypto !== 'undefined' &&
    typeof globalThis.crypto.getRandomValues === 'function'
  ) {
    const bytes = new Uint8Array(16);
    globalThis.crypto.getRandomValues(bytes);
    /* eslint-disable no-bitwise -- RFC 4122 requires setting these version/variant bits */
    bytes[6] = (bytes[6]! & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8]! & 0x3f) | 0x80; // variant 1
    /* eslint-enable no-bitwise */
    const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join(
      ''
    );
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(
      12,
      16
    )}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }
  // Fallback for older Hermes: timestamp + random suffix for uniqueness
  return `${Date.now().toString(36)}-${Math.random()
    .toString(36)
    .slice(2, 10)}`;
}

export function setQueueOptions(options: QueueOptions): void {
  _globalQueue.setOptions(options);
}

export function getQueueStatus(): QueueStatus {
  return _globalQueue.getStatus();
}

/** Settles a running background download from JS (used by `cancelDownload`). */
const _backgroundWatchers = new Map<string, (r: DownloadResult) => void>();

async function _runDownload(
  options: DownloadOptions
): Promise<RunningDownload> {
  let progressSubscription: any = null;
  let retrySubscription: any = null;
  let completeSubscription: any = null;
  let errorSubscription: any = null;
  const downloadId = options.downloadId || _generateId();
  const knownDownloadId: string = downloadId;
  _ownDownloadIds.delete(knownDownloadId); // re-insert as most recent
  _ownDownloadIds.add(knownDownloadId);
  if (_ownDownloadIds.size > MAX_OWN_DOWNLOAD_IDS) {
    _ownDownloadIds.delete(_ownDownloadIds.values().next().value!);
  }
  let _lastProgressTs: number | null = null;
  let _lastProgressBytes: number = 0;
  let _smoothedSpeedBps: number = 0;

  if (options.onProgress) {
    progressSubscription = getEventEmitter().addListener(
      'onDownloadProgress',
      (event: any) => {
        const matchesId = event.downloadId === knownDownloadId;
        const matchesUrl = !event.downloadId && event.url === options.url;
        if ((matchesId || matchesUrl) && options.onProgress) {
          const now = Date.now();
          const percent = event.progress ?? 0;
          const bytesDownloaded = event.bytesDownloaded ?? 0;
          const totalBytes = event.totalBytes ?? 0;
          let speedBps = 0;
          let etaSeconds = 0;
          if (_lastProgressTs !== null) {
            const dtSec = (now - _lastProgressTs) / 1000;
            if (dtSec > 0) {
              const bytesDelta = bytesDownloaded - _lastProgressBytes;
              if (bytesDelta > 0) {
                const instantSpeed = bytesDelta / dtSec;
                _smoothedSpeedBps =
                  _smoothedSpeedBps === 0
                    ? instantSpeed
                    : 0.3 * instantSpeed + 0.7 * _smoothedSpeedBps;
                speedBps = _smoothedSpeedBps;
                // totalBytes is -1 when the server sent no Content-Length
                etaSeconds =
                  speedBps > 0 && totalBytes > 0
                    ? (totalBytes - bytesDownloaded) / speedBps
                    : 0;
              }
            }
          }
          _lastProgressTs = now;
          _lastProgressBytes = bytesDownloaded;
          options.onProgress!({
            percent,
            bytesDownloaded,
            totalBytes,
            speedBps,
            etaSeconds,
          });
        }
      }
    );
  }

  if (options.retry?.onRetry) {
    retrySubscription = getEventEmitter().addListener(
      'onDownloadRetry',
      (event: any) => {
        const matchesId = event.downloadId === knownDownloadId;
        const matchesUrl = !event.downloadId && event.url === options.url;
        if ((matchesId || matchesUrl) && options.retry?.onRetry) {
          options.retry.onRetry(event.attempt, event.error ?? '');
        }
      }
    );
  }

  const cleanup = () => {
    progressSubscription?.remove();
    progressSubscription = null;
    retrySubscription?.remove();
    retrySubscription = null;
    completeSubscription?.remove();
    completeSubscription = null;
    errorSubscription?.remove();
    errorSubscription = null;
  };

  let settle!: (r: DownloadResult) => void;
  const settled = new Promise<DownloadResult>((resolve) => (settle = resolve));
  let finished = false;
  const finish = (r: DownloadResult) => {
    if (finished) return;
    finished = true;
    cleanup();
    if (_backgroundWatchers.get(knownDownloadId) === finish) {
      _backgroundWatchers.delete(knownDownloadId);
    }
    settle(r);
  };

  if (options.background) {
    // Subscribe before starting so a fast terminal event cannot be missed.
    completeSubscription = getEventEmitter().addListener(
      'onDownloadComplete',
      (event: any) => {
        if (event?.downloadId !== knownDownloadId) return;
        finish({
          success: event.success !== false,
          downloadId: knownDownloadId,
          filePath: event.filePath,
          error: event.error,
        });
      }
    );
    errorSubscription = getEventEmitter().addListener(
      'onDownloadError',
      (event: any) => {
        if (event?.downloadId !== knownDownloadId) return;
        finish({
          success: false,
          downloadId: knownDownloadId,
          error: event.error || 'UNKNOWN_ERROR',
        });
      }
    );
    // A second call reusing a running id is rejected by native
    // (DOWNLOAD_ID_IN_USE); it must not displace the first download's watcher.
    if (!_backgroundWatchers.has(knownDownloadId)) {
      _backgroundWatchers.set(knownDownloadId, finish);
    }
  }

  try {
    // Strip JS-only fields — functions cannot be serialized across the native bridge
    const nativeOpts: any = {
      ...options,
      downloadId,
      background: options.background ?? false,
      headers: options.headers ?? {},
      destination: options.destination ?? 'downloads',
    };
    // Strip JS-only fields — functions cannot be serialized across the native bridge
    delete nativeOpts.onProgress;
    delete nativeOpts.queue;
    delete nativeOpts.priority;
    if (nativeOpts.retry) {
      // Reconstruct retry without the onRetry callback to prevent function leak.
      // `delay` is only sent when set: native treats a missing key as the
      // 1000 ms default, while an explicit 0 means "retry immediately".
      const { attempts, delay } = nativeOpts.retry;
      nativeOpts.retry = { attempts: attempts ?? 0 };
      if (typeof delay === 'number') nativeOpts.retry.delay = delay;
    }
    const result: DownloadResult = await (FileToolkitModule as any).download(
      nativeOpts
    );
    // A background download resolves as soon as it is handed to the OS, long
    // before any bytes arrive. Tearing the listeners down here would silently
    // swallow every `onProgress` / `onRetry` callback, so keep them alive until
    // the terminal event for this download id arrives.
    const stillRunning =
      !!nativeOpts.background && !!result?.success && !result?.filePath;
    if (!stillRunning) finish(result);
    return { result, settled };
  } catch (error: any) {
    const failed: DownloadResult = {
      success: false,
      downloadId: knownDownloadId,
      error: error?.message || 'UNKNOWN_ERROR',
    };
    finish(failed);
    return { result: failed, settled };
  }
}

function _startDownload(options: DownloadOptions): Promise<RunningDownload> {
  if (options.queue) return _globalQueue.enqueue(options);
  return _runDownload(options);
}

export async function download(
  options: DownloadOptions
): Promise<DownloadResult> {
  return (await _startDownload(options)).result;
}

export async function upload(options: UploadOptions): Promise<UploadResult> {
  let sub: any = null;
  const uploadId = options.uploadId || _generateId();
  if (options.onProgress) {
    sub = getEventEmitter().addListener('onUploadProgress', (e: any) => {
      if (e.uploadId === uploadId) options.onProgress!(e.progress);
    });
  }
  try {
    // Strip onProgress callback — functions cannot be serialized across the native bridge
    const nativeUploadOpts: any = {
      ...options,
      filePath: _path(options.filePath),
      uploadId,
      fieldName: options.fieldName ?? 'file',
      headers: options.headers ?? {},
      parameters: options.parameters ?? {},
    };
    delete nativeUploadOpts.onProgress;
    const res = await (FileToolkitModule as any).upload(nativeUploadOpts);
    sub?.remove();
    return { ...res, uploadId } as UploadResult;
  } catch (err: any) {
    sub?.remove();
    return { success: false, error: err?.message || 'UNKNOWN_ERROR', uploadId };
  }
}

export async function pauseDownload(id: string): Promise<ActionResult> {
  try {
    return await (FileToolkitModule as any).pauseDownload(id);
  } catch (err: any) {
    return { success: false, error: err.message || 'UNKNOWN_ERROR' };
  }
}

export async function resumeDownload(id: string): Promise<ActionResult> {
  try {
    return await (FileToolkitModule as any).resumeDownload(id);
  } catch (err: any) {
    return { success: false, error: err.message || 'UNKNOWN_ERROR' };
  }
}

export async function cancelDownload(id: string): Promise<ActionResult> {
  // Still waiting in the JS queue — native has never seen this id.
  if (_globalQueue.cancel(id)) return { success: true };
  try {
    const res = await (FileToolkitModule as any).cancelDownload(id);
    // Cancelling a background download emits no terminal event, so release
    // its listeners (and its queue slot) here.
    if (res?.success) _backgroundWatchers.get(id)?.(_cancelledResult(id));
    return res;
  } catch (err: any) {
    return { success: false, error: err.message || 'UNKNOWN_ERROR' };
  }
}

export async function getCachedFiles(): Promise<CacheResult> {
  try {
    return await (FileToolkitModule as any).getCachedFiles();
  } catch (err: any) {
    return { success: false, error: err.message || 'UNKNOWN_ERROR' };
  }
}

export async function deleteFile(path: string): Promise<ActionResult> {
  try {
    return await (FileToolkitModule as any).deleteFile(_path(path));
  } catch (err: any) {
    return { success: false, error: err.message || 'UNKNOWN_ERROR' };
  }
}

export async function clearCache(): Promise<ActionResult> {
  try {
    return await (FileToolkitModule as any).clearCache();
  } catch (err: any) {
    return { success: false, error: err.message || 'UNKNOWN_ERROR' };
  }
}

export interface BackgroundDownloadInfo {
  downloadId: string;
  url: string;
  status: number;
  progress: number;
}

export interface BackgroundDownloadsResult {
  success: boolean;
  downloads?: BackgroundDownloadInfo[];
  error?: string;
}

export async function getBackgroundDownloads(): Promise<BackgroundDownloadsResult> {
  try {
    return await (FileToolkitModule as any).getBackgroundDownloads();
  } catch (err: any) {
    return { success: false, error: err.message || 'UNKNOWN_ERROR' };
  }
}

function _ensure(res: any, msg: string) {
  if (!res?.success) throw new Error(res?.error || msg);
}

export async function exists(path: string): Promise<boolean> {
  const res = await (FileToolkitModule as any).exists(_path(path));
  _ensure(res, 'EXISTS_ERROR');
  return !!res.exists;
}

export async function stat(path: string): Promise<FsStat> {
  const res = await (FileToolkitModule as any).stat(_path(path));
  _ensure(res, 'STAT_ERROR');
  return res.stat;
}

export async function readFile(
  path: string,
  enc: FsEncoding = 'utf8'
): Promise<string> {
  const res = await (FileToolkitModule as any).readFile(_path(path), enc);
  _ensure(res, 'READ_ERROR');
  return res.data ?? '';
}

export async function writeFile(
  path: string,
  data: string,
  enc: FsEncoding = 'utf8'
): Promise<void> {
  const res = await (FileToolkitModule as any).writeFile(
    _path(path),
    data,
    enc
  );
  _ensure(res, 'WRITE_ERROR');
}

export async function copyFile(from: string, to: string): Promise<void> {
  const res = await (FileToolkitModule as any).copyFile(_path(from), _path(to));
  _ensure(res, 'COPY_ERROR');
}

export async function moveFile(from: string, to: string): Promise<void> {
  const res = await (FileToolkitModule as any).moveFile(_path(from), _path(to));
  _ensure(res, 'MOVE_ERROR');
}

export async function mkdir(path: string): Promise<void> {
  const res = await (FileToolkitModule as any).mkdir(_path(path));
  _ensure(res, 'MKDIR_ERROR');
}

export async function ls(path: string): Promise<string[]> {
  const res = await (FileToolkitModule as any).ls(_path(path));
  _ensure(res, 'LS_ERROR');
  return res.entries || [];
}

export async function df(): Promise<DiskSpaceResult> {
  try {
    return await (FileToolkitModule as any).df();
  } catch (err: any) {
    return { success: false, error: err.message || 'DF_ERROR' };
  }
}

export async function appendFile(
  path: string,
  data: string,
  enc: FsEncoding = 'utf8'
): Promise<void> {
  const res = await (FileToolkitModule as any).appendFile(
    _path(path),
    data,
    enc
  );
  _ensure(res, 'APPEND_ERROR');
}

export async function hash(
  path: string,
  algorithm: HashAlgorithm = 'md5'
): Promise<HashResult> {
  try {
    return await (FileToolkitModule as any).hash(_path(path), algorithm);
  } catch (err: any) {
    return { success: false, error: err.message || 'HASH_ERROR' };
  }
}

export async function getCookies(domain: string): Promise<CookiesResult> {
  try {
    return await (FileToolkitModule as any).getCookies(domain);
  } catch (err: any) {
    return { success: false, error: err.message || 'GET_COOKIES_ERROR' };
  }
}

export async function clearAllCookies(): Promise<ActionResult> {
  return clearCookies('');
}

export async function clearCookies(domain: string = ''): Promise<ActionResult> {
  try {
    return await (FileToolkitModule as any).clearCookies(domain);
  } catch (err: any) {
    return { success: false, error: err.message || 'CLEAR_COOKIES_ERROR' };
  }
}

export async function saveToMediaStore(
  opts: MediaStoreOptions
): Promise<MediaStoreResult> {
  try {
    return await (FileToolkitModule as any).saveToMediaStore({
      filePath: _path(opts.filePath),
      mediaType: opts.mediaType ?? 'download',
      album: opts.album,
    });
  } catch (err: any) {
    return { success: false, error: err.message || 'MEDIA_STORE_ERROR' };
  }
}

// ─── Session Management (JS-only) ──────────────────────────────────────────

const _sessionRegistry = new Map<string, Set<string>>();

function _sessionAdd(sessionId: string, filePath: string): void {
  let set = _sessionRegistry.get(sessionId);
  if (!set) {
    set = new Set();
    _sessionRegistry.set(sessionId, set);
  }
  set.add(filePath);
}

function _sessionGet(sessionId: string): string[] {
  const set = _sessionRegistry.get(sessionId);
  return set ? Array.from(set) : [];
}

async function _sessionClear(sessionId: string): Promise<ActionResult> {
  const set = _sessionRegistry.get(sessionId);
  if (!set) return { success: true };
  const errors: string[] = [];
  for (const filePath of set) {
    const res = await deleteFile(filePath);
    if (!res.success && res.error) errors.push(res.error);
  }
  _sessionRegistry.delete(sessionId);
  return errors.length > 0
    ? { success: false, error: errors.join('; ') }
    : { success: true };
}

async function _sessionClearAll(): Promise<ActionResult> {
  const errors: string[] = [];
  for (const [sessionId] of _sessionRegistry) {
    const res = await _sessionClear(sessionId);
    if (!res.success && res.error) errors.push(res.error);
  }
  return errors.length > 0
    ? { success: false, error: errors.join('; ') }
    : { success: true };
}

/**
 * Session management API for grouping downloaded files into named sessions.
 *
 * @remarks
 * Sessions are stored in JS memory only — they do **not** persist across app
 * restarts or React Native hot-reloads. Use sessions for temporary grouping
 * within a single app lifecycle (e.g., clearing temp files on user logout).
 */
export const session: SessionApi = {
  add: _sessionAdd,
  get: _sessionGet,
  clear: _sessionClear,
  clearAll: _sessionClearAll,
};

export const cookies = {
  get: getCookies,
  clear: clearCookies,
  clearAll: clearAllCookies,
};

/**
 * File system API — POSIX-style operations.
 *
 * @remarks
 * `fs.exists`, `stat`, `readFile`, `writeFile`, `appendFile`, `copyFile`,
 * `moveFile`, `deleteFile`, `mkdir` and `ls` **throw** on failure. `fs.df` and
 * `fs.hash` return `{ success: false, error }` instead. Note that the
 * top-level `deleteFile()` also returns `{ success: false }` rather than
 * throwing.
 *
 * To avoid IDE auto-import conflicts with Node's built-in `fs`, consider:
 * ```ts
 * import { fs as fileSystem } from 'rn-file-toolkit';
 * ```
 */
export const fs: FsApi = {
  exists,
  stat,
  readFile,
  writeFile,
  appendFile,
  copyFile,
  moveFile,
  deleteFile: async (p) => {
    const res = await (FileToolkitModule as any).deleteFile(_path(p));
    _ensure(res, 'DEL_ERROR');
  },
  mkdir,
  ls,
  df,
  hash,
};

export interface DownloadCompleteEvent {
  success: boolean;
  downloadId: string;
  filePath?: string;
  error?: string;
}

export interface DownloadErrorEvent {
  success: boolean;
  downloadId: string;
  error: string;
}

export interface UploadProgressEvent {
  url: string;
  uploadId: string;
  progress: number;
}

export interface DownloadRetryEvent {
  downloadId: string;
  url: string;
  attempt: number;
  error: string;
}

/**
 * Fires when a background download finishes. Results that arrive while nothing
 * is subscribed (e.g. a download that completed while the app was closed) are
 * kept — up to 100 — and delivered to the next subscriber.
 */
export function onDownloadComplete(
  cb: (event: DownloadCompleteEvent) => void
): () => void {
  return _subscribeTerminalEvent('onDownloadComplete', cb);
}
/** Fires when a background download fails. Buffered like `onDownloadComplete`. */
export function onDownloadError(
  cb: (event: DownloadErrorEvent) => void
): () => void {
  return _subscribeTerminalEvent('onDownloadError', cb);
}
export function onUploadProgress(
  cb: (event: UploadProgressEvent) => void
): () => void {
  const s = getEventEmitter().addListener(
    'onUploadProgress',
    cb as (event: any) => void
  );
  return () => s.remove();
}
export function onDownloadRetry(
  cb: (event: DownloadRetryEvent) => void
): () => void {
  const s = getEventEmitter().addListener(
    'onDownloadRetry',
    cb as (event: any) => void
  );
  return () => s.remove();
}

/** "image/svg+xml" → "svg", "text/plain" → "txt", "" → "bin". */
function _extensionForMime(mime: string): string {
  const subtype = mime.split('/')[1]?.split('+')[0]?.trim().toLowerCase();
  if (!subtype || subtype === 'octet-stream') return 'bin';
  return subtype === 'plain' ? 'txt' : subtype;
}

export async function saveBase64AsFile(
  opts: SaveBase64Options
): Promise<SaveBase64Result> {
  try {
    let { base64Data, fileName, destination } = opts;
    if (base64Data.startsWith('data:')) {
      // data:[<mediatype>][;param=value]*[;base64],<data>  (RFC 2397)
      const comma = base64Data.indexOf(',');
      const meta = base64Data.slice(5, comma).split(';');
      if (comma === -1 || meta[meta.length - 1]!.toLowerCase() !== 'base64') {
        return {
          success: false,
          error:
            'Invalid data URI: only base64-encoded data URIs are supported',
        };
      }
      base64Data = base64Data.slice(comma + 1);
      if (!fileName) {
        fileName = `file_${Date.now()}.${_extensionForMime(meta[0]!)}`;
      }
    }
    return await FileToolkitModule.saveBase64AsFile({
      base64Data,
      fileName,
      destination,
    });
  } catch (err: any) {
    return { success: false, error: err.message || 'UNKNOWN_ERROR' };
  }
}

export async function urlToBase64(
  opts: UrlToBase64Options
): Promise<UrlToBase64Result> {
  try {
    return await FileToolkitModule.urlToBase64(opts);
  } catch (err: any) {
    return { success: false, error: err.message || 'UNKNOWN_ERROR' };
  }
}

export async function shareFile(
  opts: ShareFileOptions
): Promise<ShareFileResult> {
  try {
    return await FileToolkitModule.shareFile(_path(opts.filePath), {
      title: opts.title,
      subject: opts.subject,
    });
  } catch (err: any) {
    return { success: false, error: err.message || 'UNKNOWN_ERROR' };
  }
}

export async function openFile(opts: OpenFileOptions): Promise<OpenFileResult> {
  try {
    return await FileToolkitModule.openFile(
      _path(opts.filePath),
      opts.mimeType || ''
    );
  } catch (err: any) {
    return { success: false, error: err.message || 'UNKNOWN_ERROR' };
  }
}

export interface UnzipResult {
  success: boolean;
  destDir?: string;
  files?: string[];
  error?: string;
}

export interface ZipResult {
  success: boolean;
  zipPath?: string;
  error?: string;
}

export async function unzip(
  sourcePath: string,
  destDir: string
): Promise<UnzipResult> {
  try {
    return await (FileToolkitModule as any).unzip(
      _path(sourcePath),
      _path(destDir)
    );
  } catch (err: any) {
    return { success: false, error: err?.message || 'UNZIP_ERROR' };
  }
}

export async function zip(
  sourcePath: string,
  destPath: string
): Promise<ZipResult> {
  try {
    return await (FileToolkitModule as any).zip(
      _path(sourcePath),
      _path(destPath)
    );
  } catch (err: any) {
    return { success: false, error: err?.message || 'ZIP_ERROR' };
  }
}

export interface UseDownloadReturn {
  start: (options: DownloadOptions) => Promise<DownloadResult>;
  pause: () => Promise<void>;
  resume: () => Promise<void>;
  cancel: () => Promise<void>;
  status: 'idle' | 'downloading' | 'paused' | 'done' | 'error';
  progress: ProgressInfo | null;
  result: DownloadResult | null;
  downloadId: string | null;
}

/**
 * React hook for managing a single download with progress, pause/resume, and cancel.
 *
 * @remarks
 * The `start` callback is memoised with an empty dependency array but uses a
 * ref internally to always read the **latest** `onProgress` callback you pass,
 * so you do not need to memoise your options object.
 *
 * The hook tracks one download at a time: calling `start` while a download is
 * still running cancels it first. For `background: true` downloads, `status`
 * stays `'downloading'` until the OS reports the outcome, then `result` holds
 * the final `filePath` (or `error`).
 */
export function useDownload(): UseDownloadReturn {
  const [status, setStatus] = useState<any>('idle');
  const [progress, setProgress] = useState<ProgressInfo | null>(null);
  const [result, setResult] = useState<DownloadResult | null>(null);
  const [downloadId, setDownloadId] = useState<string | null>(null);
  const downloadIdRef = useRef<string | null>(null);
  const latestOptsRef = useRef<DownloadOptions | null>(null);
  const mountedRef = useRef(false);

  // Cancel any in-flight download when the component unmounts to prevent
  // native event listeners from calling setState on an unmounted component.
  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      if (downloadIdRef.current) {
        cancelDownload(downloadIdRef.current);
        downloadIdRef.current = null;
      }
    };
  }, []);

  const start = useCallback(async (opts: DownloadOptions) => {
    const previous = downloadIdRef.current;
    if (previous) {
      // Forget it first so its late progress/result cannot overwrite this one.
      downloadIdRef.current = null;
      await cancelDownload(previous);
    }
    latestOptsRef.current = opts;
    const id = opts.downloadId || _generateId();
    const isCurrent = () => mountedRef.current && downloadIdRef.current === id;
    downloadIdRef.current = id;
    setStatus('downloading');
    setProgress(null);
    setResult(null);
    setDownloadId(id);
    const run = await _startDownload({
      ...opts,
      downloadId: id,
      onProgress: (p) => {
        if (!isCurrent()) return;
        setProgress(p);
        // Always call the latest onProgress — avoids stale-closure issues
        latestOptsRef.current?.onProgress?.(p);
      },
    });
    const res = run.result;
    if (!isCurrent()) return res;
    setResult(res);
    const stillRunning = !!opts.background && !!res.success && !res.filePath;
    if (!stillRunning) {
      setStatus(res.success ? 'done' : 'error');
      // The download has settled — forget the id so that unmounting the component
      // does not fire a pointless `cancelDownload` against a finished download.
      downloadIdRef.current = null;
      return res;
    }
    run.settled.then((final) => {
      if (!isCurrent()) return;
      downloadIdRef.current = null;
      setResult(final);
      setStatus(final.success ? 'done' : 'error');
    });
    return res;
  }, []);

  const pause = useCallback(async () => {
    if (downloadIdRef.current) {
      const res = await pauseDownload(downloadIdRef.current);
      if (res.success) setStatus('paused');
    }
  }, []);
  const resume = useCallback(async () => {
    if (downloadIdRef.current) {
      const res = await resumeDownload(downloadIdRef.current);
      if (res.success) setStatus('downloading');
    }
  }, []);
  const cancel = useCallback(async () => {
    const id = downloadIdRef.current;
    if (id) {
      // Forget the id first so the cancelled download's settling is ignored.
      downloadIdRef.current = null;
      await cancelDownload(id);
      if (!mountedRef.current) return;
      setStatus('idle');
      setProgress(null);
      setResult(null);
      setDownloadId(null);
    }
  }, []);

  return { start, pause, resume, cancel, status, progress, result, downloadId };
}

/**
 * Default export — provides all APIs as a single namespace.
 *
 * **For optimal tree-shaking, prefer named imports:**
 * ```ts
 * import { download, upload, fs } from 'rn-file-toolkit';
 * ```
 *
 * **Error handling patterns:**
 * - Most functions (`download`, `upload`, `deleteFile`, `unzip`, `df`, `hash`,
 *   etc.) return `{ success: boolean; error?: string }` and **never throw**.
 * - The filesystem functions `exists`, `stat`, `readFile`, `writeFile`,
 *   `appendFile`, `copyFile`, `moveFile`, `mkdir` and `ls` **throw** on
 *   failure — whether called top-level or via `fs.*` — as does
 *   `fs.deleteFile`.
 * - `useDownload()` sets `status` to `'error'` on failure.
 */
export default {
  isAvailable,
  download,
  upload,
  pauseDownload,
  resumeDownload,
  cancelDownload,
  getCachedFiles,
  deleteFile,
  clearCache,
  getBackgroundDownloads,
  saveBase64AsFile,
  urlToBase64,
  shareFile,
  openFile,
  onDownloadComplete,
  onDownloadError,
  onUploadProgress,
  onDownloadRetry,
  setQueueOptions,
  getQueueStatus,
  exists,
  stat,
  readFile,
  writeFile,
  appendFile,
  copyFile,
  moveFile,
  mkdir,
  ls,
  df,
  hash,
  getCookies,
  clearCookies,
  clearAllCookies,
  saveToMediaStore,
  fs,
  cookies,
  session,
  useDownload,
  unzip,
  zip,
};
