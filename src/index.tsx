import { useState, useCallback, useRef } from 'react';
import { NativeEventEmitter, NativeModules } from 'react-native';
import FileToolkitSpec from './NativeFileToolkit';

const FileToolkitModule = NativeModules.FileToolkit || FileToolkitSpec;
const eventEmitter = new NativeEventEmitter(FileToolkitModule);

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
  notificationTitle?: string;
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

export interface FsApi {
  exists: (filePath: string) => Promise<boolean>;
  stat: (filePath: string) => Promise<FsStat>;
  readFile: (filePath: string, encoding?: FsEncoding) => Promise<string>;
  writeFile: (
    filePath: string,
    data: string,
    encoding?: FsEncoding
  ) => Promise<void>;
  copyFile: (fromPath: string, toPath: string) => Promise<void>;
  moveFile: (fromPath: string, toPath: string) => Promise<void>;
  deleteFile: (filePath: string) => Promise<void>;
  mkdir: (dirPath: string) => Promise<void>;
  ls: (dirPath: string) => Promise<string[]>;
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
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === 'x' ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
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
    progressSubscription = eventEmitter.addListener(
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
    retrySubscription = eventEmitter.addListener(
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
    const result = await (FileToolkitModule as any).download({
      ...options,
      downloadId,
      background: options.background ?? false,
      headers: options.headers ?? {},
      destination: options.destination ?? 'downloads',
    });
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
    sub = eventEmitter.addListener('onUploadProgress', (e: any) => {
      if (e.uploadId === uploadId) options.onProgress!(e.progress);
    });
  }
  try {
    const res = await (FileToolkitModule as any).upload({
      ...options,
      uploadId,
      fieldName: options.fieldName ?? 'file',
      headers: options.headers ?? {},
      parameters: options.parameters ?? {},
    });
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

export async function getBackgroundDownloads(): Promise<any> {
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

export const fs: FsApi = {
  exists,
  stat,
  readFile,
  writeFile,
  copyFile,
  moveFile,
  deleteFile: async (p) => {
    _ensure(await deleteFile(p), 'DEL_ERROR');
  },
  mkdir,
  ls,
};

export function onDownloadComplete(cb: any) {
  const s = eventEmitter.addListener('onDownloadComplete', cb);
  return () => s.remove();
}
export function onDownloadError(cb: any) {
  const s = eventEmitter.addListener('onDownloadError', cb);
  return () => s.remove();
}
export function onUploadProgress(cb: any) {
  const s = eventEmitter.addListener('onUploadProgress', cb);
  return () => s.remove();
}
export function onDownloadRetry(cb: any) {
  const s = eventEmitter.addListener('onDownloadRetry', cb);
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

export async function unzip(s: string, d: string): Promise<UnzipResult> {
  try {
    return await (FileToolkitModule as any).unzip(s, d);
  } catch {
    return { success: false, error: 'UNZIP_ERROR' };
  }
}

export async function zip(s: string, d: string): Promise<ZipResult> {
  try {
    return await (FileToolkitModule as any).zip(s, d);
  } catch {
    return { success: false, error: 'ZIP_ERROR' };
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

export function useDownload(): UseDownloadReturn {
  const [status, setStatus] = useState<any>('idle');
  const [progress, setProgress] = useState<ProgressInfo | null>(null);
  const [result, setResult] = useState<DownloadResult | null>(null);
  const [downloadId, setDownloadId] = useState<string | null>(null);
  const downloadIdRef = useRef<string | null>(null);

  const start = useCallback(async (opts: DownloadOptions) => {
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
        opts.onProgress?.(p);
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
      await pauseDownload(downloadIdRef.current);
      setStatus('paused');
    }
  }, []);
  const resume = useCallback(async () => {
    if (downloadIdRef.current) {
      await resumeDownload(downloadIdRef.current);
      setStatus('downloading');
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
  copyFile,
  moveFile,
  mkdir,
  ls,
  fs,
  useDownload,
  unzip,
  zip,
};
