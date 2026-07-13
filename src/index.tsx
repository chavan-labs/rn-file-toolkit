import { useState, useCallback, useRef, useEffect } from 'react';
import { NativeEventEmitter, NativeModules } from 'react-native';
import FileToolkitSpec from './NativeFileToolkit';

const FileToolkitModule = NativeModules.FileToolkit || FileToolkitSpec;

let _eventEmitter: NativeEventEmitter | null = null;
function getEventEmitter(): NativeEventEmitter {
  if (!_eventEmitter) {
    _eventEmitter = new NativeEventEmitter(FileToolkitModule);
  }
  return _eventEmitter;
}

export interface ProgressInfo {
  percent: number;
  bytesDownloaded: number;
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
  options: DownloadOptions;
  resolve: (result: DownloadResult) => void;
  reject: (reason?: any) => void;
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

  enqueue(options: DownloadOptions): Promise<DownloadResult> {
    return new Promise<DownloadResult>((resolve, reject) => {
      const item: QueueItem = { options, resolve, reject };
      if (options.priority === 'high') {
        this._queue.unshift(item);
      } else {
        this._queue.push(item);
      }
      this._flush();
    });
  }

  private _flush(): void {
    while (this._active < this._maxConcurrent && this._queue.length > 0) {
      const item = this._queue.shift()!;
      this._active++;
      const nativeOptions = { ...item.options };
      delete nativeOptions.queue;
      delete nativeOptions.priority;
      _executeDownload(nativeOptions)
        .then((result) => {
          item.resolve(result);
        })
        .catch((err) => {
          item.reject(err);
        })
        .finally(() => {
          this._active--;
          this._flush();
        });
    }
  }
}

const _globalQueue = new DownloadQueue();

function _generateId(): string {
  // Use crypto.getRandomValues (available on Hermes since RN 0.73) for collision resistance
  if (
    typeof globalThis.crypto !== 'undefined' &&
    typeof globalThis.crypto.getRandomValues === 'function'
  ) {
    const bytes = new Uint8Array(16);
    globalThis.crypto.getRandomValues(bytes);
    bytes[6] = (bytes[6]! & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8]! & 0x3f) | 0x80; // variant 1
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

async function _executeDownload(
  options: DownloadOptions
): Promise<DownloadResult> {
  let progressSubscription: any = null;
  let retrySubscription: any = null;
  const downloadId = options.downloadId || _generateId();
  const knownDownloadId: string = downloadId;
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
              if (bytesDelta > 0 && totalBytes > 0) {
                const instantSpeed = bytesDelta / dtSec;
                _smoothedSpeedBps =
                  _smoothedSpeedBps === 0
                    ? instantSpeed
                    : 0.3 * instantSpeed + 0.7 * _smoothedSpeedBps;
                speedBps = _smoothedSpeedBps;
                etaSeconds =
                  speedBps > 0 ? (totalBytes - bytesDownloaded) / speedBps : 0;
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
    retrySubscription?.remove();
  };

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
      // Reconstruct retry without the onRetry callback to prevent function leak
      nativeOpts.retry = {
        attempts: nativeOpts.retry.attempts ?? 0,
        delay: nativeOpts.retry.delay,
      };
    }
    const result = await (FileToolkitModule as any).download(nativeOpts);
    cleanup();
    return result as DownloadResult;
  } catch (error: any) {
    cleanup();
    return { success: false, error: error?.message || 'UNKNOWN_ERROR' };
  }
}

export function download(options: DownloadOptions): Promise<DownloadResult> {
  if (options.queue) return _globalQueue.enqueue(options);
  return _executeDownload(options);
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
  try {
    return await (FileToolkitModule as any).cancelDownload(id);
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
    return await (FileToolkitModule as any).deleteFile(path);
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
  const res = await (FileToolkitModule as any).exists(path);
  _ensure(res, 'EXISTS_ERROR');
  return !!res.exists;
}

export async function stat(path: string): Promise<FsStat> {
  const res = await (FileToolkitModule as any).stat(path);
  _ensure(res, 'STAT_ERROR');
  return res.stat;
}

export async function readFile(
  path: string,
  enc: FsEncoding = 'utf8'
): Promise<string> {
  const res = await (FileToolkitModule as any).readFile(path, enc);
  _ensure(res, 'READ_ERROR');
  return res.data ?? '';
}

export async function writeFile(
  path: string,
  data: string,
  enc: FsEncoding = 'utf8'
): Promise<void> {
  const res = await (FileToolkitModule as any).writeFile(path, data, enc);
  _ensure(res, 'WRITE_ERROR');
}

export async function copyFile(from: string, to: string): Promise<void> {
  const res = await (FileToolkitModule as any).copyFile(from, to);
  _ensure(res, 'COPY_ERROR');
}

export async function moveFile(from: string, to: string): Promise<void> {
  const res = await (FileToolkitModule as any).moveFile(from, to);
  _ensure(res, 'MOVE_ERROR');
}

export async function mkdir(path: string): Promise<void> {
  const res = await (FileToolkitModule as any).mkdir(path);
  _ensure(res, 'MKDIR_ERROR');
}

export async function ls(path: string): Promise<string[]> {
  const res = await (FileToolkitModule as any).ls(path);
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
  const res = await (FileToolkitModule as any).appendFile(path, data, enc);
  _ensure(res, 'APPEND_ERROR');
}

export async function hash(
  path: string,
  algorithm: HashAlgorithm = 'md5'
): Promise<HashResult> {
  try {
    return await (FileToolkitModule as any).hash(path, algorithm);
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

export async function clearCookies(domain: string): Promise<ActionResult> {
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
      filePath: opts.filePath,
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
 * All `fs.*` methods **throw** on failure (via exceptions), unlike top-level
 * helpers such as `deleteFile()` which return `{ success: false }`.
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
    const res = await (FileToolkitModule as any).deleteFile(p);
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

export function onDownloadComplete(
  cb: (event: DownloadCompleteEvent) => void
): () => void {
  const s = getEventEmitter().addListener(
    'onDownloadComplete',
    cb as (event: any) => void
  );
  return () => s.remove();
}
export function onDownloadError(
  cb: (event: DownloadErrorEvent) => void
): () => void {
  const s = getEventEmitter().addListener(
    'onDownloadError',
    cb as (event: any) => void
  );
  return () => s.remove();
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

export async function saveBase64AsFile(
  opts: SaveBase64Options
): Promise<SaveBase64Result> {
  try {
    let { base64Data, fileName, destination } = opts;
    if (base64Data.startsWith('data:')) {
      const m = base64Data.match(/^data:([^;]+);base64,(.+)$/);
      if (m && m[2]) {
        base64Data = m[2];
        if (!fileName && m[1])
          fileName = `file_${Date.now()}.${m[1].split('/')[1] || 'bin'}`;
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
    return await FileToolkitModule.shareFile(opts.filePath, {
      title: opts.title,
      subject: opts.subject,
    });
  } catch (err: any) {
    return { success: false, error: err.message || 'UNKNOWN_ERROR' };
  }
}

export async function openFile(opts: OpenFileOptions): Promise<OpenFileResult> {
  try {
    return await FileToolkitModule.openFile(opts.filePath, opts.mimeType || '');
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
    return await (FileToolkitModule as any).unzip(sourcePath, destDir);
  } catch (err: any) {
    return { success: false, error: err?.message || 'UNZIP_ERROR' };
  }
}

export async function zip(
  sourcePath: string,
  destPath: string
): Promise<ZipResult> {
  try {
    return await (FileToolkitModule as any).zip(sourcePath, destPath);
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
 */
export function useDownload(): UseDownloadReturn {
  const [status, setStatus] = useState<any>('idle');
  const [progress, setProgress] = useState<ProgressInfo | null>(null);
  const [result, setResult] = useState<DownloadResult | null>(null);
  const [downloadId, setDownloadId] = useState<string | null>(null);
  const downloadIdRef = useRef<string | null>(null);
  const latestOptsRef = useRef<DownloadOptions | null>(null);

  // Cancel any in-flight download when the component unmounts to prevent
  // native event listeners from calling setState on an unmounted component.
  useEffect(() => {
    return () => {
      if (downloadIdRef.current) {
        cancelDownload(downloadIdRef.current);
      }
    };
  }, []);

  const start = useCallback(async (opts: DownloadOptions) => {
    latestOptsRef.current = opts;
    const id = opts.downloadId || _generateId();
    setStatus('downloading');
    setProgress(null);
    setResult(null);
    setDownloadId(id);
    downloadIdRef.current = id;
    const res = await download({
      ...opts,
      downloadId: id,
      onProgress: (p) => {
        setProgress(p);
        // Always call the latest onProgress — avoids stale-closure issues
        latestOptsRef.current?.onProgress?.(p);
      },
    });
    setResult(res);
    setStatus(
      !!opts.background && !!res.success && !!res.downloadId && !res.filePath
        ? 'downloading'
        : res.success
        ? 'done'
        : 'error'
    );
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
    if (downloadIdRef.current) {
      await cancelDownload(downloadIdRef.current);
      setStatus('idle');
      setProgress(null);
      setResult(null);
      downloadIdRef.current = null;
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
 * - Top-level functions (`download`, `upload`, `deleteFile`, etc.) return
 *   `{ success: boolean; error?: string }` and **never throw**.
 * - `fs.*` methods **throw** on failure via exceptions.
 * - `useDownload()` sets `status` to `'error'` on failure.
 */
export default {
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
