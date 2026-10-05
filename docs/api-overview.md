# API Overview

This page summarizes the public API you can use in your app code.

## Downloads

### `download(options)`

Starts a download and returns a `DownloadResult`.

Main options:

- `url: string` (required)
- `destination?: 'downloads' | 'cache' | 'documents'`
- `fileName?: string`
- `headers?: Record<string, string>`
- `background?: boolean`
- `notificationTitle?: string`
- `notificationDescription?: string`
- `downloadId?: string`
- `onProgress?: (info) => void`
- `queue?: boolean`
- `priority?: 'high' | 'normal'`
- `retry?: { attempts: number; delay?: number; onRetry?: (...) => void }`
- `checksum?: { hash: string; algorithm: 'md5' | 'sha1' | 'sha256' }`

Progress payload (`ProgressInfo`):

- `percent` — 0–100, or `-1` when the server sends no `Content-Length`
- `bytesDownloaded`
- `totalBytes` — `-1` when the server sends no `Content-Length`
- `speedBps`
- `etaSeconds`

Result (`DownloadResult`):

- `success: boolean`
- `filePath?: string` — not set for `background: true`; the path arrives with `onDownloadComplete`
- `downloadId?: string`
- `error?: string`

### `pauseDownload(downloadId)` / `resumeDownload(downloadId)` / `cancelDownload(downloadId)`

Control an active download by ID. Returns `Promise<ActionResult>`:

- `success: boolean`
- `error?: string`

Pausing keeps the partial file; resuming continues with an HTTP `Range` request (or restarts if the server ignores it). `cancelDownload()` also removes a download still waiting in the queue — its `download()` promise resolves with `{ success: false, error: 'CANCELLED' }`.

- Starting a download with a `downloadId` that is still running resolves with `error: 'DOWNLOAD_ID_IN_USE'` (Android). Cancel it first, or use a new id.
- On Android, `cancelDownload()` resolves with `error: 'ALREADY_COMPLETED'` when the download finished before the cancel took effect.
- On Android, a connection that ends before the expected number of bytes arrived is retried (with `retry`) or fails with `error: 'INCOMPLETE_DOWNLOAD: received <n> of <expected> bytes'` instead of saving a truncated file.
- While a foreground download is in progress, Android writes it to a hidden `.<name>.<random>.part` file in the destination folder and renames it when complete. `getCachedFiles()` skips these files; `ls()` shows them.

### `getBackgroundDownloads()`

Returns `{ success, downloads?, error? }`, where `downloads` lists the running or pending background tasks as `{ downloadId, url, status, progress }`, so you can re-attach to them after an app restart. `status` is the raw platform value (see troubleshooting).

### `setQueueOptions({ maxConcurrent })`

Sets global queue concurrency for queued downloads. Queued background downloads keep their slot until they finish.

### `getQueueStatus()`

Returns:

- `active`
- `pending`
- `maxConcurrent`

### `useDownload()`

Use this hook for UI-centric download flows.

Returns:

- `start(options)`
- `pause()`
- `resume()`
- `cancel()`
- `status: 'idle' | 'downloading' | 'paused' | 'done' | 'error'`
- `progress`
- `result`
- `downloadId`

## Uploads

### `upload(options)`

Multipart upload with progress callback.

Options:

- `url: string`
- `filePath: string`
- `fieldName?: string` (default `file`)
- `headers?: Record<string, string>`
- `parameters?: Record<string, string>`
- `uploadId?: string`
- `onProgress?: (percent: number) => void`

Result:

- `success: boolean`
- `status?: number`
- `data?: string`
- `error?: string`
- `uploadId?: string`

## Filesystem

You can call top-level methods or use the grouped `fs` object.

### Core methods

- `exists(path): Promise<boolean>`
- `stat(path): Promise<FsStat>`
- `readFile(path, encoding?): Promise<string>`
- `writeFile(path, data, encoding?): Promise<void>`
- `copyFile(fromPath, toPath): Promise<void>`
- `moveFile(fromPath, toPath): Promise<void>`
- `deleteFile(path): Promise<ActionResult>`
- `mkdir(path): Promise<void>`
- `ls(path): Promise<string[]>`

`encoding` supports:

- `utf8`
- `base64`

`FsStat` fields:

- `path`
- `name`
- `size`
- `modified`
- `isDir`

## Cache helpers

- `getCachedFiles(): Promise<CacheResult>`
- `clearCache(): Promise<ActionResult>`

`CacheResult` fields:

- `success: boolean`
- `files?: CachedFile[]`
- `error?: string`

`CachedFile` fields:

- `fileName: string`
- `filePath: string`
- `size: number`
- `modifiedAt: number`

## Base64 and media utilities

### `saveBase64AsFile(options)`

Options:

- `base64Data` (raw base64 or full data URI)
- `fileName?`
- `destination?: 'downloads' | 'cache' | 'documents'`

If a data URI is provided and `fileName` is omitted, file extension is inferred when possible.

Result (`SaveBase64Result`):

- `success: boolean`
- `filePath?: string`
- `error?: string`

### `urlToBase64(options)`

Options:

- `url`
- `headers?`

Result:

- `success`
- `base64`
- `mimeType`
- `dataUri`
- `error`

### `shareFile(options)`

Options:

- `filePath`
- `title?`
- `subject?`

Result (`ShareFileResult`):

- `success: boolean`
- `completed?: boolean`
- `error?: string`

### `openFile(options)`

Options:

- `filePath`
- `mimeType?`

Result (`OpenFileResult`):

- `success: boolean`
- `error?: string`

## Archive APIs

- `zip(sourcePath, destinationZipPath): Promise<ZipResult>`
- `unzip(sourceZipPath, destinationDir): Promise<UnzipResult>`

`ZipResult` fields:

- `success: boolean`
- `zipPath?: string`
- `error?: string`

`UnzipResult` fields:

- `success: boolean`
- `destDir?: string`
- `files?: string[]`
- `error?: string`

## Disk Space

### `df()`

Returns free and total disk space in bytes.

Result (`DiskSpaceResult`):

- `success: boolean`
- `freeBytes?: number`
- `totalBytes?: number`
- `error?: string`

Also available as `fs.df()`.

## File Appending

### `appendFile(path, data, encoding?)`

Appends data to an existing file (creates the file if it doesn't exist). Unlike `writeFile`, this does not overwrite existing content.

- `path: string` — target file path
- `data: string` — content to append
- `encoding?: 'utf8' | 'base64'` — defaults to `utf8`

Throws on failure (consistent with `writeFile`).

Also available as `fs.appendFile()`.

## File Hashing

### `hash(filePath, algorithm?)`

Computes the hash digest of a file on disk.

- `filePath: string` — path to the file
- `algorithm?: 'md5' | 'sha1' | 'sha256'` — defaults to `md5`

Result (`HashResult`):

- `success: boolean`
- `hash?: string` — hex-encoded hash string
- `error?: string`

Also available as `fs.hash()`.

## Session Management

Group downloaded/created files into named sessions for batch management.

### `session.add(sessionId, filePath)`

Register a file path under a session.

### `session.get(sessionId)`

Returns `string[]` — all file paths in the session.

### `session.clear(sessionId)`

Deletes all files in the session from disk and removes the session. Returns `Promise<ActionResult>`.

### `session.clearAll()`

Clears all sessions and their files. Returns `Promise<ActionResult>`.

> **Note:** Session management runs entirely in JavaScript. Session data does not persist across app restarts.

## Cookie Management

### `getCookies(domain)`

Returns cookies matching the given domain from the platform's shared cookie store.

- `domain: string` — the domain to match

Result (`CookiesResult`):

- `success: boolean`
- `cookies?: Cookie[]`
- `error?: string`

`Cookie` fields:

- `name: string`
- `value: string`
- `domain: string`
- `path: string`
- `expiresDate?: number` (timestamp in ms, iOS only)
- `isSecure?: boolean` (iOS only)
- `isHTTPOnly?: boolean` (iOS only)

Also available as `cookies.get(domain)`.

### `clearCookies(domain?)`

Clears cookies matching the given domain. Pass an empty string `''` to clear **all** cookies.

- `domain?: string` — defaults to `''` (clear all)

Returns `Promise<ActionResult>`.

Also available as `cookies.clear(domain)`.

## MediaStore / Photos Library

### `saveToMediaStore(options)`

Saves a file to the device's shared media store (Android MediaStore API / iOS Photos Library).

Options (`MediaStoreOptions`):

- `filePath: string` (required) — path to the source file
- `mediaType?: 'image' | 'video' | 'audio' | 'download'` — defaults to `download`
- `album?: string` — optional album (iOS) or subfolder (Android) name

Result (`MediaStoreResult`):

- `success: boolean`
- `uri?: string` — content URI (Android) or file path (iOS)
- `error?: string`

**Platform notes:**

- **Android:** Uses `MediaStore` ContentResolver API on Android 10+ (scoped storage). Falls back to public directory copy + `MediaScannerConnection` on Android 9-.
- **iOS:** Uses `PHPhotoLibrary` for images and videos. For audio/download types, copies the file to the Documents directory (iOS has no shared media store for these types).
- **Permissions:**
  - **iOS:** `NSPhotoLibraryAddUsageDescription` in `Info.plist`; saving into an `album` additionally needs `NSPhotoLibraryUsageDescription`. A missing key resolves with `success: false` instead of crashing.
  - **Android 9 and below:** `WRITE_EXTERNAL_STORAGE` (declare it with `android:maxSdkVersion="28"` and request it at runtime; the Expo plugin declares it for you). Without it the call resolves with `success: false`.

## Events

Subscribe helpers:

- `onDownloadComplete(callback)` — background downloads
- `onDownloadError(callback)` — background downloads
- `onUploadProgress(callback)`
- `onDownloadRetry(callback)`

Each returns an unsubscribe function.
