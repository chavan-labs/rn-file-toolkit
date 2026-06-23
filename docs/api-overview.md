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

- `percent`
- `bytesDownloaded`
- `totalBytes`
- `speedBps`
- `etaSeconds`

Result (`DownloadResult`):

- `success: boolean`
- `filePath?: string`
- `downloadId?: string`
- `error?: string`

### `pauseDownload(downloadId)` / `resumeDownload(downloadId)` / `cancelDownload(downloadId)`

Control an active download by ID. Returns `Promise<ActionResult>`:

- `success: boolean`
- `error?: string`

### `getBackgroundDownloads()`

Returns an array of actively running or pending background download tasks, allowing you to re-attach or manage them after app restart.

### `setQueueOptions({ maxConcurrent })`

Sets global queue concurrency for queued downloads.

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

## Events

Subscribe helpers:

- `onDownloadComplete(callback)`
- `onDownloadError(callback)`
- `onUploadProgress(callback)`
- `onDownloadRetry(callback)`

Each returns an unsubscribe function.
