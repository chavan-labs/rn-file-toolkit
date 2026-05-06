import { useState, useCallback, useRef } from 'react';
import { NativeEventEmitter, NativeModules } from 'react-native';
import FileToolkitSpec from './NativeFileToolkit';

const FileToolkitModule = NativeModules.FileToolkit || FileToolkitSpec;
const eventEmitter = new NativeEventEmitter(FileToolkitModule);

// ─── Types ────────────────────────────────────────────────────────────────────

/**
 * Rich progress information emitted during a download.
 * Replaces the plain `number` percent from earlier versions.
 */
export interface ProgressInfo {
  /** Download progress as a percentage (0–100) */
  percent: number;
  /** Number of bytes downloaded so far */
  bytesDownloaded: number;
  /** Total file size in bytes (0 if unknown) */
  totalBytes: number;
  /** Current download speed in bytes per second */
  speedBps: number;
  /** Estimated seconds remaining (0 if unknown) */
  etaSeconds: number;
}

export interface DownloadOptions {
  /** Remote URL to download from */
  url: string;
  /** Optional file name. Auto-detected from URL if not provided */
  fileName?: string;
  /**
   * Run as a background download.
   * - iOS: uses NSURLSession background configuration
   * - Android: uses system DownloadManager
   * Background downloads survive app suspension. Listen to `onDownloadComplete`
   * and `onDownloadError` events instead of awaiting the promise.
   */
  background?: boolean;
  /** Custom request headers (e.g. Authorization) */
  headers?: Record<string, string>;
  /**
   * Destination directory for the downloaded file.
   * - 'downloads': Public Downloads folder (default)
   * - 'cache': App-private cache directory (cleared by OS when space is low)
   * - 'documents': App-private documents directory (persisted)
   */
  destination?: 'downloads' | 'cache' | 'documents';
  /** Android only: custom title for the system download notification */
  notificationTitle?: string;
  /** Android only: custom description for the system download notification */
  notificationDescription?: string;
  /** Optional checksum verification after download completes */
  checksum?: {
    hash: string;
    algorithm: 'md5' | 'sha1' | 'sha256';
  };
  /** Called with rich progress info during foreground downloads */
  onProgress?: (info: ProgressInfo) => void;
  /**
   * Join the managed download queue instead of starting immediately.
   * Respects the `maxConcurrent` limit set via `setQueueOptions()`.
   * Defaults to `false`.
   */
  queue?: boolean;
  /**
   * Priority inside the queue.
   * - `'high'`: inserted at the front of the pending queue.
   * - `'normal'` (default): appended to the back.
   * Has no effect when `queue` is `false`.
   */
  priority?: 'high' | 'normal';
  /**
   * Auto-retry on network failure with exponential backoff.
   * Only retries on network errors (timeouts, connection drops).
   * Server errors (4xx/5xx) and checksum mismatches are NOT retried.
   *
   * @example
   * ```ts
   * download({
   *   url: '...',
   *   retry: {
   *     attempts: 3,
   *     delay: 1000,       // 1s → 2s → 4s (doubles each time, capped at 30s)
   *     onRetry: (attempt, error) => console.log(`Retry #${attempt}: ${error}`),
   *   }
   * })
   * ```
   */
  retry?: {
    /** Maximum number of retry attempts (default: 0 = no retry) */
    attempts: number;
    /** Base delay in ms between retries. Doubles each attempt (default: 1000) */
    delay?: number;
    /** Called just before each retry attempt */
    onRetry?: (attempt: number, error: string) => void;
  };
}

export interface UploadOptions {
  /** Remote URL to upload to */
  url: string;
  /** Absolute local path of the file to upload */
  filePath: string;
  /** Multi-part field name for the file (default: 'file') */
  fieldName?: string;
  /** Custom request headers */
  headers?: Record<string, string>;
  /** Additional text parameters for the multi-part request */
  parameters?: Record<string, string>;
  /** Called with progress 0–100 during upload */
  onProgress?: (percent: number) => void;
}

export interface DownloadResult {
  success: boolean;
  /** Local path of the saved file */
  filePath?: string;
  /** Unique ID for this download — use with pause/resume/cancel */
  downloadId?: string;
  /** Error message if success is false */
  error?: string;
}

export interface UploadResult {
  success: boolean;
  /** HTTP response status code */
  status?: number;
  /** HTTP response body as string (if any) */
  data?: string;
  /** Error message if success is false */
  error?: string;
}

export interface ActionResult {
  success: boolean;
  error?: string;
}

export interface CachedFile {
  fileName: string;
  filePath: string;
  /** File size in bytes */
  size: number;
  /** Last-modified timestamp in milliseconds */
  modifiedAt: number;
}

export interface CacheResult {
  success: boolean;
  files?: CachedFile[];
  error?: string;
}

export interface SaveBase64Options {
  /**
   * Base64 string or data URI (e.g., "data:image/png;base64,iVBORw0...")
   * If a data URI is provided, the base64 portion will be extracted automatically.
   */
  base64Data: string;
  /** Optional file name. Auto-generated if not provided */
  fileName?: string;
  /**
   * Destination directory for the saved file.
   * - 'downloads': Public Downloads folder (default)
   * - 'cache': App-private cache directory
   * - 'documents': App-private documents directory
   */
  destination?: 'downloads' | 'cache' | 'documents';
}

export interface SaveBase64Result {
  success: boolean;
  /** Local path of the saved file */
  filePath?: string;
  /** Error message if success is false */
  error?: string;
}

export interface UrlToBase64Options {
  /** URL of the file to convert to base64 (image, video, gif, etc.) */
  url: string;
  /** Optional custom headers (e.g., Authorization) */
  headers?: Record<string, string>;
}

export interface UrlToBase64Result {
  success: boolean;
  /** Base64-encoded string */
  base64?: string;
  /** MIME type detected from response (e.g., 'image/png') */
  mimeType?: string;
  /** Complete data URI (e.g., 'data:image/png;base64,...') */
  dataUri?: string;
  /** Error message if success is false */
  error?: string;
}

export interface ShareFileOptions {
  /** Absolute path to the file to share */
  filePath: string;
  /** Optional title for the share dialog (Android only) */
  title?: string;
  /** Optional subject for email sharing (Android only) */
  subject?: string;
}

export interface OpenFileOptions {
  /** Absolute path to the file to open */
  filePath: string;
  /** MIME type of the file (e.g., 'application/pdf', 'image/jpeg'). Auto-detected if not provided. */
  mimeType?: string;
}

export interface ShareFileResult {
  success: boolean;
  /** Whether user completed the share action (iOS only) */
  completed?: boolean;
  /** Error message if success is false */
  error?: string;
}

export interface OpenFileResult {
  success: boolean;
  /** Error message if success is false */
  error?: string;
}

export type FsEncoding = 'utf8' | 'base64';

export interface FsStat {
  /** Absolute path */
  path: string;
  /** Basename */
  name: string;
  /** Size in bytes (0 for directories) */
  size: number;
  /** Last modified timestamp in milliseconds */
  modified: number;
  /** Whether path is a directory */
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

// ─── Queue ───────────────────────────────────────────────────────────────────

export interface QueueOptions {
  /**
   * Maximum number of simultaneous downloads when using the managed queue.
   * Defaults to `3`.
   */
  maxConcurrent?: number;
}

export interface QueueStatus {
  /** Number of downloads actively running right now */
  active: number;
  /** Number of downloads waiting in the queue */
  pending: number;
  /** Current `maxConcurrent` setting */
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
      // Kick off any slots that just opened.
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
      // Strip queue-specific fields before passing to the native layer.
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

/**
 * Configure the global managed download queue.
 *
 * @example
 * ```ts
 * setQueueOptions({ maxConcurrent: 3 });
 * ```
 */
export function setQueueOptions(options: QueueOptions): void {
  _globalQueue.setOptions(options);
}

/**
 * Get the current state of the managed download queue.
 *
 * @example
 * ```ts
 * const { active, pending, maxConcurrent } = getQueueStatus();
 * ```
 */
export function getQueueStatus(): QueueStatus {
  return _globalQueue.getStatus();
}

// ─── Core download ────────────────────────────────────────────────────────────

/**
 * Core native download executor — used internally by `download()` and the queue.
 * Never routes through the queue.
 */
async function _executeDownload(
  options: DownloadOptions
): Promise<DownloadResult> {
  let progressSubscription: ReturnType<typeof eventEmitter.addListener> | null =
    null;
  let retrySubscription: ReturnType<typeof eventEmitter.addListener> | null =
    null;

  // downloadId is resolved immediately on Android foreground, allowing
  // ID-based event filtering. On iOS it only arrives on completion, so we
  // fall back to URL-based filtering in that case.
  let knownDownloadId: string | null = null;

  // Speed / ETA tracking (JS-side, works regardless of native platform)
  let _lastProgressTs: number | null = null;
  let _lastProgressBytes: number = 0;
  // Smoothed speed using exponential moving average (α = 0.3)
  let _smoothedSpeedBps: number = 0;

  if (options.onProgress) {
    progressSubscription = eventEmitter.addListener(
      'onDownloadProgress',
      (event: any) => {
        const matchesId =
          knownDownloadId && event.downloadId === knownDownloadId;
        const matchesUrl = !knownDownloadId && event.url === options.url;
        if ((matchesId || matchesUrl) && options.onProgress) {
          const now = Date.now();
          const percent: number = event.progress ?? 0;
          const bytesDownloaded: number = event.bytesDownloaded ?? 0;
          const totalBytes: number = event.totalBytes ?? 0;

          let speedBps = 0;
          let etaSeconds = 0;

          if (_lastProgressTs !== null) {
            const dtSec = (now - _lastProgressTs) / 1000;
            if (dtSec > 0) {
              const bytesDelta = bytesDownloaded - _lastProgressBytes;
              // Only update speed if we have byte-level data from native
              if (bytesDelta > 0 && totalBytes > 0) {
                const instantSpeed = bytesDelta / dtSec;
                // Exponential moving average for smoother readings
                _smoothedSpeedBps =
                  _smoothedSpeedBps === 0
                    ? instantSpeed
                    : 0.3 * instantSpeed + 0.7 * _smoothedSpeedBps;
                speedBps = _smoothedSpeedBps;
                const remaining = totalBytes - bytesDownloaded;
                etaSeconds = speedBps > 0 ? remaining / speedBps : 0;
              } else if (percent > 0 && percent < 100) {
                // Fallback: estimate from percent when bytes aren't available
                const estimatedTotalBytes =
                  totalBytes > 0
                    ? totalBytes
                    : _lastProgressBytes / (percent / 100);
                const percentDelta =
                  percent - (_lastProgressBytes / estimatedTotalBytes) * 100;
                if (percentDelta > 0) {
                  const estimatedByteDelta =
                    (percentDelta / 100) * estimatedTotalBytes;
                  const instantSpeed = estimatedByteDelta / dtSec;
                  _smoothedSpeedBps =
                    _smoothedSpeedBps === 0
                      ? instantSpeed
                      : 0.3 * instantSpeed + 0.7 * _smoothedSpeedBps;
                  speedBps = _smoothedSpeedBps;
                  const remainingPct = 100 - percent;
                  const estimatedRemaining =
                    (remainingPct / 100) * estimatedTotalBytes;
                  etaSeconds = speedBps > 0 ? estimatedRemaining / speedBps : 0;
                }
              }
            }
          }

          _lastProgressTs = now;
          _lastProgressBytes = bytesDownloaded;

          const info: ProgressInfo = {
            percent,
            bytesDownloaded,
            totalBytes,
            speedBps,
            etaSeconds,
          };
          options.onProgress(info);
        }
      }
    );
  }

  if (options.retry?.onRetry) {
    retrySubscription = eventEmitter.addListener(
      'onDownloadRetry',
      (event: any) => {
        const matchesId =
          knownDownloadId && event.downloadId === knownDownloadId;
        const matchesUrl = !knownDownloadId && event.url === options.url;
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
    const resultPromise = (FileToolkitSpec as any).download({
      url: options.url,
      fileName: options.fileName,
      background: options.background ?? false,
      headers: options.headers ?? {},
      destination: options.destination ?? 'downloads',
      notificationTitle: options.notificationTitle,
      notificationDescription: options.notificationDescription,
      checksum: options.checksum,
      retry: options.retry
        ? {
            attempts: options.retry.attempts,
            delay: options.retry.delay ?? 1000,
          }
        : undefined,
    });

    // On Android foreground the promise resolves immediately with downloadId,
    // giving us a precise ID to filter events by before download completes.
    // On iOS it only resolves on completion, so knownDownloadId stays null
    // and URL-based filtering is used as the fallback.
    resultPromise.then?.((partial: any) => {
      if (partial?.downloadId && !partial?.filePath) {
        // Android early-resolve: has downloadId but no filePath yet
        knownDownloadId = partial.downloadId;
      }
    });

    const result = await resultPromise;
    cleanup();
    return result as DownloadResult;
  } catch (error: any) {
    cleanup();
    return { success: false, error: error?.message || 'UNKNOWN_ERROR' };
  }
}

/**
 * Download a file.
 *
 * For **foreground** downloads the promise resolves when the file is saved.
 * For **background** downloads the promise resolves immediately with a
 * `downloadId`; listen to the `onDownloadComplete` / `onDownloadError`
 * events for the final result.
 *
 * Pass `queue: true` to join the managed queue and respect the `maxConcurrent`
 * limit configured via `setQueueOptions()`. Use `priority: 'high'` to jump
 * ahead of other pending items in the queue.
 *
 * @example
 * ```ts
 * // Direct (unqueued) download
 * const result = await download({ url: 'https://...' });
 *
 * // Queued download with high priority
 * setQueueOptions({ maxConcurrent: 3 });
 * const result = await download({
 *   url: 'https://...',
 *   queue: true,
 *   priority: 'high',
 * });
 * ```
 */
export function download(options: DownloadOptions): Promise<DownloadResult> {
  if (options.queue) {
    return _globalQueue.enqueue(options);
  }
  return _executeDownload(options);
}

// ─── Core upload ───────────────────────────────────────────────────────────────

/**
 * Upload a file using multipart/form-data.
 */
export async function upload(options: UploadOptions): Promise<UploadResult> {
  let progressSubscription: ReturnType<typeof eventEmitter.addListener> | null =
    null;

  if (options.onProgress) {
    progressSubscription = eventEmitter.addListener(
      'onUploadProgress',
      (event: any) => {
        if (event.url === options.url && options.onProgress) {
          options.onProgress(event.progress);
        }
      }
    );
  }

  try {
    const result = await (FileToolkitSpec as any).upload({
      url: options.url,
      filePath: options.filePath,
      fieldName: options.fieldName ?? 'file',
      headers: options.headers ?? {},
      parameters: options.parameters ?? {},
    });

    if (progressSubscription) {
      progressSubscription.remove();
    }

    return result as UploadResult;
  } catch (error: any) {
    if (progressSubscription) {
      progressSubscription.remove();
    }
    return { success: false, error: error?.message || 'UNKNOWN_ERROR' };
  }
}

// ─── Pause / Resume / Cancel ──────────────────────────────────────────────────

/**
 * Pause an active foreground download.
 * On iOS the partial data is stored so it can be resumed.
 * On Android the download thread is suspended.
 */
export async function pauseDownload(downloadId: string): Promise<ActionResult> {
  try {
    return (await (FileToolkitSpec as any).pauseDownload(
      downloadId
    )) as ActionResult;
  } catch (error: any) {
    return { success: false, error: error?.message || 'UNKNOWN_ERROR' };
  }
}

/**
 * Resume a previously paused download.
 * On iOS resumes from partial data (HTTP Range). On Android unblocks the thread.
 */
export async function resumeDownload(
  downloadId: string
): Promise<ActionResult> {
  try {
    return (await (FileToolkitSpec as any).resumeDownload(
      downloadId
    )) as ActionResult;
  } catch (error: any) {
    return { success: false, error: error?.message || 'UNKNOWN_ERROR' };
  }
}

/**
 * Cancel and discard a download (foreground or background).
 * Any partially-downloaded file is deleted.
 */
export async function cancelDownload(
  downloadId: string
): Promise<ActionResult> {
  try {
    return (await (FileToolkitSpec as any).cancelDownload(
      downloadId
    )) as ActionResult;
  } catch (error: any) {
    return { success: false, error: error?.message || 'UNKNOWN_ERROR' };
  }
}

// ─── Cache management ─────────────────────────────────────────────────────────

/**
 * List all files in the app's cache directory.
 */
export async function getCachedFiles(): Promise<CacheResult> {
  try {
    return (await (FileToolkitSpec as any).getCachedFiles()) as CacheResult;
  } catch (error: any) {
    return { success: false, error: error?.message || 'UNKNOWN_ERROR' };
  }
}

/**
 * Delete a single file by its absolute path.
 */
export async function deleteFile(filePath: string): Promise<ActionResult> {
  try {
    return (await (FileToolkitSpec as any).deleteFile(
      filePath
    )) as ActionResult;
  } catch (error: any) {
    return { success: false, error: error?.message || 'UNKNOWN_ERROR' };
  }
}

/**
 * Delete all files in the app's cache directory.
 */
export async function clearCache(): Promise<ActionResult> {
  try {
    return (await (FileToolkitSpec as any).clearCache()) as ActionResult;
  } catch (error: any) {
    return { success: false, error: error?.message || 'UNKNOWN_ERROR' };
  }
}

/**
 * Get all active background downloads.
 * Use this after app restart to "re-attach" to ongoing downloads.
 */
export async function getBackgroundDownloads(): Promise<{
  success: boolean;
  downloads?: Array<{
    downloadId: string;
    url: string;
    status: number;
    progress: number;
  }>;
  error?: string;
}> {
  try {
    return (await (FileToolkitSpec as any).getBackgroundDownloads()) as any;
  } catch (error: any) {
    return { success: false, error: error?.message || 'UNKNOWN_ERROR' };
  }
}

// ─── File system helpers ─────────────────────────────────────────────────────

function _ensureFsSuccess(result: any, fallback: string): void {
  if (!result?.success) {
    throw new Error(result?.error || fallback);
  }
}

/** Check whether a file or directory exists. */
export async function exists(filePath: string): Promise<boolean> {
  const result = await (FileToolkitSpec as any).exists(filePath);
  _ensureFsSuccess(result, 'EXISTS_ERROR');
  return !!result.exists;
}

/** Get file or directory metadata. */
export async function stat(filePath: string): Promise<FsStat> {
  const result = await (FileToolkitSpec as any).stat(filePath);
  _ensureFsSuccess(result, 'STAT_ERROR');
  return result.stat as FsStat;
}

/** Read a file as utf8 (default) or base64 string. */
export async function readFile(
  filePath: string,
  encoding: FsEncoding = 'utf8'
): Promise<string> {
  const result = await (FileToolkitSpec as any).readFile(filePath, encoding);
  _ensureFsSuccess(result, 'READ_FILE_ERROR');
  return result.data ?? '';
}

/** Write utf8 (default) or base64 data to a file. */
export async function writeFile(
  filePath: string,
  data: string,
  encoding: FsEncoding = 'utf8'
): Promise<void> {
  const result = await (FileToolkitSpec as any).writeFile(
    filePath,
    data,
    encoding
  );
  _ensureFsSuccess(result, 'WRITE_FILE_ERROR');
}

/** Copy a file from source to destination. */
export async function copyFile(
  fromPath: string,
  toPath: string
): Promise<void> {
  const result = await (FileToolkitSpec as any).copyFile(fromPath, toPath);
  _ensureFsSuccess(result, 'COPY_FILE_ERROR');
}

/** Move a file from source to destination. */
export async function moveFile(
  fromPath: string,
  toPath: string
): Promise<void> {
  const result = await (FileToolkitSpec as any).moveFile(fromPath, toPath);
  _ensureFsSuccess(result, 'MOVE_FILE_ERROR');
}

/** Create a directory recursively. */
export async function mkdir(dirPath: string): Promise<void> {
  const result = await (FileToolkitSpec as any).mkdir(dirPath);
  _ensureFsSuccess(result, 'MKDIR_ERROR');
}

/** List direct entries (names) in a directory. */
export async function ls(dirPath: string): Promise<string[]> {
  const result = await (FileToolkitSpec as any).ls(dirPath);
  _ensureFsSuccess(result, 'LS_ERROR');
  return (result.entries || []) as string[];
}

/**
 * File system API namespace.
 *
 * @example
 * ```ts
 * import { fs } from 'rn-file-toolkit';
 *
 * const ok = await fs.exists('/path/to/file.pdf');
 * const meta = await fs.stat('/path/to/file.pdf');
 * const text = await fs.readFile('/path/to/file.txt');
 * ```
 */
export const fs: FsApi = {
  exists,
  stat,
  readFile,
  writeFile,
  copyFile,
  moveFile,
  deleteFile: async (filePath: string) => {
    const result = await deleteFile(filePath);
    _ensureFsSuccess(result, 'DELETE_FILE_ERROR');
  },
  mkdir,
  ls,
};

// ─── Event helpers ────────────────────────────────────────────────────────────

/**
 * Subscribe to background download completion events.
 * Returns an unsubscribe function.
 */
export function onDownloadComplete(
  callback: (result: DownloadResult) => void
): () => void {
  const sub = eventEmitter.addListener('onDownloadComplete', callback as any);
  return () => sub.remove();
}

/**
 * Subscribe to background download error events.
 * Returns an unsubscribe function.
 */
export function onDownloadError(
  callback: (result: DownloadResult) => void
): () => void {
  const sub = eventEmitter.addListener('onDownloadError', callback as any);
  return () => sub.remove();
}

/**
 * Subscribe to upload progress events.
 * Returns an unsubscribe function.
 */
export function onUploadProgress(
  callback: (result: { url: string; progress: number }) => void
): () => void {
  const sub = eventEmitter.addListener('onUploadProgress', callback as any);
  return () => sub.remove();
}

/**
 * Subscribe to download retry events (fired before each retry attempt).
 * Returns an unsubscribe function.
 */
export function onDownloadRetry(
  callback: (result: {
    downloadId: string;
    url: string;
    attempt: number;
  }) => void
): () => void {
  const sub = eventEmitter.addListener('onDownloadRetry', callback as any);
  return () => sub.remove();
}

// ─── saveBase64AsFile ─────────────────────────────────────────────────────────

/**
 * Save a base64 string or data URI as a file.
 * Supports data URIs (e.g., "data:image/png;base64,iVBORw0...") and plain base64 strings.
 *
 * @example
 * ```typescript
 * // From data URI
 * const result = await saveBase64AsFile({
 *   base64Data: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUg...',
 *   fileName: 'photo.png',
 *   destination: 'documents'
 * });
 *
 * // From plain base64
 * const result = await saveBase64AsFile({
 *   base64Data: 'SGVsbG8gV29ybGQ=',
 *   fileName: 'hello.txt',
 *   destination: 'cache'
 * });
 * ```
 */
export async function saveBase64AsFile(
  options: SaveBase64Options
): Promise<SaveBase64Result> {
  try {
    let { base64Data, fileName, destination } = options;

    // Parse data URI if present (e.g., "data:image/png;base64,iVBORw0...")
    if (base64Data.startsWith('data:')) {
      const matches = base64Data.match(/^data:([^;]+);base64,(.+)$/);
      if (matches && matches[2]) {
        base64Data = matches[2];

        // Auto-detect file extension from MIME type if fileName not provided
        if (!fileName && matches[1]) {
          const mimeType = matches[1];
          const ext = mimeType.split('/')[1] || 'bin';
          fileName = `file_${Date.now()}.${ext}`;
        }
      } else {
        return {
          success: false,
          error:
            'Invalid data URI format. Expected: data:<mimetype>;base64,<data>',
        };
      }
    }

    const result = await FileToolkitModule.saveBase64AsFile({
      base64Data,
      fileName,
      destination,
    });

    return result as SaveBase64Result;
  } catch (error: any) {
    return { success: false, error: error?.message || 'UNKNOWN_ERROR' };
  }
}

// ─── urlToBase64 ──────────────────────────────────────────────────────────────

/**
 * Convert a web URL (image, video, gif, etc.) to base64 string.
 * Downloads the file and returns both the base64 string and data URI format.
 *
 * @example
 * ```typescript
 * // Convert image to base64
 * const result = await urlToBase64({
 *   url: 'https://example.com/photo.jpg',
 *   headers: { Authorization: 'Bearer token' }
 * });
 *
 * if (result.success) {
 *   console.log('Base64:', result.base64);
 *   console.log('Data URI:', result.dataUri);
 *   console.log('MIME Type:', result.mimeType);
 * }
 * ```
 */
export async function urlToBase64(
  options: UrlToBase64Options
): Promise<UrlToBase64Result> {
  try {
    const result = await FileToolkitModule.urlToBase64({
      url: options.url,
      headers: options.headers,
    });

    return result as UrlToBase64Result;
  } catch (error: any) {
    return { success: false, error: error?.message || 'UNKNOWN_ERROR' };
  }
}

// ─── shareFile ────────────────────────────────────────────────────────────────

/**
 * Share a file with other apps using the native share dialog.
 * Opens the system share sheet on iOS and share chooser on Android.
 *
 * @example
 * ```typescript
 * const result = await shareFile({
 *   filePath: '/path/to/document.pdf',
 *   title: 'Share Document',
 *   subject: 'Check out this file'
 * });
 *
 * if (result.success) {
 *   console.log('File shared successfully');
 * }
 * ```
 */
export async function shareFile(
  options: ShareFileOptions
): Promise<ShareFileResult> {
  try {
    const result = await FileToolkitModule.shareFile(options.filePath, {
      title: options.title,
      subject: options.subject,
    });

    return result as ShareFileResult;
  } catch (error: any) {
    return { success: false, error: error?.message || 'UNKNOWN_ERROR' };
  }
}

// ─── openFile ─────────────────────────────────────────────────────────────────

/**
 * Open a file with the default app or app chooser.
 * On iOS, displays a preview or shows apps that can handle the file.
 * On Android, opens with the default app or shows app chooser.
 *
 * @example
 * ```typescript
 * const result = await openFile({
 *   filePath: '/path/to/document.pdf',
 *   mimeType: 'application/pdf' // optional, auto-detected if not provided
 * });
 *
 * if (result.success) {
 *   console.log('File opened successfully');
 * }
 * ```
 */
export async function openFile(
  options: OpenFileOptions
): Promise<OpenFileResult> {
  try {
    const result = await FileToolkitModule.openFile(
      options.filePath,
      options.mimeType || ''
    );

    return result as OpenFileResult;
  } catch (error: any) {
    return { success: false, error: error?.message || 'UNKNOWN_ERROR' };
  }
}

// ─── Zip / Unzip ─────────────────────────────────────────────────────────────

export interface UnzipResult {
  success: boolean;
  /** Absolute path of the destination directory */
  destDir?: string;
  /** List of absolute paths of all extracted files */
  files?: string[];
  /** Error message if success is false */
  error?: string;
}

export interface ZipResult {
  success: boolean;
  /** Absolute path of the created zip archive */
  zipPath?: string;
  /** Error message if success is false */
  error?: string;
}

/**
 * Extract a ZIP archive to a destination directory.
 *
 * Uses `java.util.zip` on Android and zlib (system framework) on iOS.
 * No third-party dependency required.
 *
 * @param sourcePath Absolute path to the `.zip` file
 * @param destDir    Absolute path to the directory where files will be extracted.
 *                   The directory is created automatically if it does not exist.
 *
 * @example
 * ```ts
 * const result = await unzip(
 *   '/path/to/archive.zip',
 *   '/path/to/output-folder'
 * );
 *
 * if (result.success) {
 *   console.log('Extracted files:', result.files);
 * }
 * ```
 */
export async function unzip(
  sourcePath: string,
  destDir: string
): Promise<UnzipResult> {
  try {
    const result = await (FileToolkitSpec as any).unzip(sourcePath, destDir);
    return result as UnzipResult;
  } catch (error: any) {
    return { success: false, error: error?.message || 'UNZIP_ERROR' };
  }
}

/**
 * Create a ZIP archive from a file or directory.
 *
 * Uses `java.util.zip` on Android and zlib (system framework) on iOS.
 * No third-party dependency required.
 *
 * @param sourcePath Absolute path to the file or directory to compress
 * @param destPath   Absolute path for the output `.zip` file.
 *                   Parent directory is created automatically if needed.
 *
 * @example
 * ```ts
 * // Zip a single file
 * const result = await zip(
 *   '/path/to/document.pdf',
 *   '/path/to/document.zip'
 * );
 *
 * // Zip an entire directory
 * const result = await zip(
 *   '/path/to/my-folder',
 *   '/path/to/my-folder.zip'
 * );
 *
 * if (result.success) {
 *   console.log('Archive created at:', result.zipPath);
 * }
 * ```
 */
export async function zip(
  sourcePath: string,
  destPath: string
): Promise<ZipResult> {
  try {
    const result = await (FileToolkitSpec as any).zip(sourcePath, destPath);
    return result as ZipResult;
  } catch (error: any) {
    return { success: false, error: error?.message || 'ZIP_ERROR' };
  }
}

// ─── useDownload hook ─────────────────────────────────────────────────────────

export type DownloadStatus =
  | 'idle'
  | 'downloading'
  | 'paused'
  | 'done'
  | 'error';

export interface UseDownloadReturn {
  /** Start a download. Resolves with the final result. */
  start: (options: DownloadOptions) => Promise<DownloadResult>;
  /** Pause the current download */
  pause: () => Promise<void>;
  /** Resume the current download */
  resume: () => Promise<void>;
  /** Cancel the current download */
  cancel: () => Promise<void>;
  /** Current status of the download */
  status: DownloadStatus;
  /** Rich progress information (null until first progress event) */
  progress: ProgressInfo | null;
  /** Final result once download completes or fails */
  result: DownloadResult | null;
  /** The active download ID (available after download starts) */
  downloadId: string | null;
}

/**
 * React hook for managing a single download with built-in state.
 *
 * Tracks status, rich progress (percent, speed, ETA), and the final result.
 * Exposes `pause`, `resume`, and `cancel` controls tied to the active download.
 *
 * @example
 * ```tsx
 * function DownloadButton() {
 *   const { start, pause, resume, cancel, status, progress, result } = useDownload();
 *
 *   return (
 *     <View>
 *       <Button
 *         title="Download"
 *         onPress={() => start({ url: 'https://example.com/file.zip' })}
 *       />
 *
 *       {status === 'downloading' && progress && (
 *         <View>
 *           <Text>{progress.percent.toFixed(1)}%</Text>
 *           <Text>Speed: {(progress.speedBps / 1024).toFixed(1)} KB/s</Text>
 *           <Text>ETA: {progress.etaSeconds.toFixed(0)}s</Text>
 *           <ProgressBar value={progress.percent / 100} />
 *           <Button title="Pause" onPress={pause} />
 *         </View>
 *       )}
 *
 *       {status === 'paused' && (
 *         <Button title="Resume" onPress={resume} />
 *       )}
 *
 *       {status === 'done' && result?.success && (
 *         <Text>Saved to: {result.filePath}</Text>
 *       )}
 *
 *       {status === 'error' && (
 *         <Text>Error: {result?.error}</Text>
 *       )}
 *     </View>
 *   );
 * }
 * ```
 */
export function useDownload(): UseDownloadReturn {
  const [status, setStatus] = useState<DownloadStatus>('idle');
  const [progress, setProgress] = useState<ProgressInfo | null>(null);
  const [result, setResult] = useState<DownloadResult | null>(null);
  const [downloadId, setDownloadId] = useState<string | null>(null);
  const downloadIdRef = useRef<string | null>(null);

  const start = useCallback(
    async (options: DownloadOptions): Promise<DownloadResult> => {
      setStatus('downloading');
      setProgress(null);
      setResult(null);
      setDownloadId(null);
      downloadIdRef.current = null;

      const res = await download({
        ...options,
        onProgress: (info: ProgressInfo) => {
          setProgress(info);
          options.onProgress?.(info);
        },
      });

      if (res.downloadId) {
        downloadIdRef.current = res.downloadId;
        setDownloadId(res.downloadId);
      }

      setResult(res);
      const isBackgroundPending =
        !!options.background &&
        !!res.success &&
        !!res.downloadId &&
        !res.filePath;
      setStatus(
        isBackgroundPending ? 'downloading' : res.success ? 'done' : 'error'
      );
      return res;
    },
    []
  );

  const pause = useCallback(async (): Promise<void> => {
    if (downloadIdRef.current) {
      await pauseDownload(downloadIdRef.current);
      setStatus('paused');
    }
  }, []);

  const resume = useCallback(async (): Promise<void> => {
    if (downloadIdRef.current) {
      await resumeDownload(downloadIdRef.current);
      setStatus('downloading');
    }
  }, []);

  const cancel = useCallback(async (): Promise<void> => {
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
