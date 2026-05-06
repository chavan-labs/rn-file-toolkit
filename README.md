# rn-file-toolkit

[![npm version](https://img.shields.io/npm/v/rn-file-toolkit.svg?style=flat-square)](https://www.npmjs.com/package/rn-file-toolkit)
[![npm downloads](https://img.shields.io/npm/dm/rn-file-toolkit.svg?style=flat-square)](https://www.npmjs.com/package/rn-file-toolkit)
[![license](https://img.shields.io/npm/l/rn-file-toolkit.svg?style=flat-square)](https://github.com/chavan-labs/rn-file-toolkit/blob/main/LICENSE)
[![TypeScript](https://img.shields.io/badge/TypeScript-Ready-blue.svg?style=flat-square)](https://www.typescriptlang.org/)
[![platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20Android-lightgrey.svg?style=flat-square)](https://github.com/chavan-labs/rn-file-toolkit)

The easiest way to download **and manage files** in React Native — with background support, pause/resume, upload, queueing, and built-in filesystem APIs.

> 100% pure native code (Kotlin + Swift). Zero third-party dependencies.

**Keywords:** react native download, react native file download, react native background download, react native download manager, react native file upload, react native download progress, react native pause resume download, react native cache manager, react native turbo module, expo download, iOS URLSession, Android DownloadManager, react native checksum validation, base64 converter, url to base64, data uri, share file, open file, file sharing, native share, document viewer, download queue, concurrent downloads, queue concurrency, priority queue, batch download, max concurrent downloads, react native filesystem, read file, write file, copy file, move file, stat file, file exists, useDownload hook, download speed, download eta, download progress bytes

⭐ **Star this repo if you found it useful** — it helps others discover the project!

## Problems?

Most React Native file download solutions have one or more of these problems:

- **Complexity** — require configuring native modules, background tasks, and notification channels separately
- **Dependencies** — rely on heavy third-party libraries that bloat your app size
- **Limited features** — lack pause/resume, checksum validation, or proper background support
- **No queue** — spawn 20 downloads and you'll crash or saturate the network; libraries like `react-native-blob-util` have no queue at all
- **Split libraries** — downloading is in one package, filesystem operations in another (read/write/copy/stat/exists), adding extra dependency and complexity
- **Poor DX** — complicated APIs that require managing multiple IDs, listeners, and cleanup logic

**rn-file-toolkit** was built to solve these issues. It provides a simple, unified API while leveraging platform-native download managers (URLSession on iOS, DownloadManager on Android) for reliable, battery-efficient downloads. Everything works out of the box — background downloads, progress tracking, pause/resume — without wrestling with native configuration.

## ✨ Features

- **`useDownload()` hook** — drop-in React hook with built-in state: `status`, `progress`, `result`, `pause`, `resume`, `cancel` — no competitors have this
- **Rich progress info** — `onProgress` gives you `percent`, `bytesDownloaded`, `totalBytes`, `speedBps`, and `etaSeconds` — not just a plain number
- **Zip & Unzip** — compress files/directories and extract ZIP archives natively with **zero third-party dependencies** (`java.util.zip` on Android, system `zlib` on iOS)
- **Download with progress** — clean `0 → 100` progress natively, no UI freezing
- **Background downloads** — survive app suspension (iOS background URLSession + Android DownloadManager)
- **Download Queue** — built-in concurrency-limited queue with `maxConcurrent` control and `high`/`normal` priority
- **Pause & Resume** — resume mid-download using HTTP Range requests
- **Auto-Retry** — automatic retry on network errors with exponential backoff
- **Cancel** — cancel any active download, partial files are cleaned up automatically
- **Re-attach** — reconnect to background downloads after app restart
- **Custom Headers** — support for Authorization tokens and custom metadata
- **Custom Destinations** — save to `downloads`, `cache`, or `documents` folders
- **Multipart Upload** — simple, native file uploading
- **Checksum Validation** — verify file integrity (MD5, SHA1, SHA256) after download
- **Base64 & Data URI Support** — convert base64 strings and data URIs to files natively
- **URL to Base64** — convert remote URLs (images, videos, gifs) to base64 strings
- **Share Files** — share files with other apps using native share dialog
- **Open Files** — open files with default apps or app chooser
- **Filesystem API (`fs`)** — `exists`, `stat`, `readFile`, `writeFile`, `copyFile`, `moveFile`, `mkdir`, `ls`, `deleteFile`
- **Expo Support** — includes a config plugin for zero-config integration
- **TurboModules** — built on the React Native New Architecture
- **File management** — list, delete individual files, or clear all downloads

---

## Installation

```sh
npm install rn-file-toolkit
```

---

## API

### `download(options)`

```javascript
import { download } from 'rn-file-toolkit';

const result = await download({
  url: 'https://example.com/file.pdf',
  fileName: 'my_file.pdf',
  headers: { Authorization: 'Bearer <token>' },
  destination: 'documents', // 'downloads' | 'cache' | 'documents'
  checksum: {
    hash: 'd41d8cd98f00b204e9800998ecf8427e',
    algorithm: 'md5',
  },
  onProgress: ({
    percent,
    bytesDownloaded,
    totalBytes,
    speedBps,
    etaSeconds,
  }) => {
    console.log(
      `${percent.toFixed(1)}% — ${(speedBps / 1024).toFixed(
        1
      )} KB/s — ETA ${etaSeconds.toFixed(0)}s`
    );
  },
  // Auto-retry on network failure (optional)
  retry: {
    attempts: 3, // max retry attempts
    delay: 1000, // base delay in ms; doubles each attempt: 1s → 2s → 4s (capped at 30s)
    onRetry: (attempt, error) => console.log(`Retry #${attempt}: ${error}`),
  },
});
```

> **Retry behaviour:**
>
> - Only retries on **network errors** (timeouts, connection drops, socket errors).
> - Server errors (`4xx`/`5xx`) and checksum mismatches are **not** retried.
> - Delay doubles each attempt (exponential backoff), capped at 30 seconds.
> - Works on both iOS and Android for foreground downloads.

---

### `setQueueOptions(options)` · `getQueueStatus()` · Queue-aware `download()`

Avoid crashing your app (or saturating the network) when kicking off many simultaneous downloads. The built-in queue lets you cap concurrency and prioritise individual items — all in pure JavaScript, with zero native changes required.

```javascript
import { download, setQueueOptions, getQueueStatus } from 'rn-file-toolkit';

// 1. Configure the global queue (call once, e.g. at app startup)
setQueueOptions({ maxConcurrent: 3 }); // default is 3

// 2. Enqueue downloads — at most 3 will run at the same time
const promises = urls.map((url) =>
  download({
    url,
    destination: 'documents',
    queue: true, // join the managed queue
    priority: 'normal', // 'high' | 'normal' (default)
    onProgress: (p) => console.log(`${url}: ${p.percent}%`),
  })
);

const results = await Promise.all(promises);

// High-priority item jumps ahead of all 'normal' pending items
download({
  url: 'https://example.com/urgent.pdf',
  queue: true,
  priority: 'high',
});

// 3. Inspect queue state at any time
const { active, pending, maxConcurrent } = getQueueStatus();
console.log(`Running: ${active}  Waiting: ${pending}  Limit: ${maxConcurrent}`);
```

> **Queue behaviour:**
>
> - `queue: false` (default) — download starts immediately, bypassing the queue entirely. All existing behaviour is unchanged.
> - `queue: true` — the download is placed in the JS queue. It starts as soon as an active slot is free.
> - `priority: 'high'` — item is inserted at the **front** of the pending list, so it runs before any `'normal'` items.
> - `priority: 'normal'` (default) — item is appended to the **back**.
> - `setQueueOptions` can be called at any time; if `maxConcurrent` is increased, idle slots are filled immediately.
> - All other `DownloadOptions` (`onProgress`, `retry`, `checksum`, `headers`, etc.) work exactly the same inside the queue.

---

### `useDownload()` hook

The easiest way to manage a download inside a React component. Get status, rich progress (with speed & ETA), and full controls — all with zero boilerplate.

```tsx
import { useDownload } from 'rn-file-toolkit';

function DownloadScreen() {
  const { start, pause, resume, cancel, status, progress, result } =
    useDownload();

  return (
    <View>
      <Button
        title="Download"
        onPress={() =>
          start({
            url: 'https://example.com/video.mp4',
            destination: 'documents',
          })
        }
      />

      {status === 'downloading' && progress && (
        <View>
          <Text>{progress.percent.toFixed(1)}%</Text>
          <Text>Speed: {(progress.speedBps / 1024).toFixed(1)} KB/s</Text>
          <Text>ETA: {progress.etaSeconds.toFixed(0)}s</Text>
          <Text>
            {(progress.bytesDownloaded / 1024 / 1024).toFixed(1)} MB
            {' / '}
            {(progress.totalBytes / 1024 / 1024).toFixed(1)} MB
          </Text>
          <Button title="Pause" onPress={pause} />
          <Button title="Cancel" onPress={cancel} />
        </View>
      )}

      {status === 'paused' && <Button title="Resume" onPress={resume} />}

      {status === 'done' && result?.success && (
        <Text>✅ Saved to: {result.filePath}</Text>
      )}

      {status === 'error' && <Text>❌ {result?.error}</Text>}
    </View>
  );
}
```

| Property         | Type                                                       | Description                     |
| ---------------- | ---------------------------------------------------------- | ------------------------------- |
| `start(options)` | `(options: DownloadOptions) => Promise<DownloadResult>`    | Start a download                |
| `pause()`        | `() => Promise<void>`                                      | Pause the active download       |
| `resume()`       | `() => Promise<void>`                                      | Resume a paused download        |
| `cancel()`       | `() => Promise<void>`                                      | Cancel and discard the download |
| `status`         | `'idle' \| 'downloading' \| 'paused' \| 'done' \| 'error'` | Current state                   |
| `progress`       | `ProgressInfo \| null`                                     | Live progress info (see below)  |
| `result`         | `DownloadResult \| null`                                   | Final result once complete      |
| `downloadId`     | `string \| null`                                           | Active download ID              |

---

### `upload(options)`

```javascript
import { upload } from 'rn-file-toolkit';

const result = await upload({
  url: 'https://example.com/api/upload',
  filePath: '/path/to/my_image.jpg',
  fieldName: 'avatar', // default: 'file'
  parameters: {
    userId: '123',
  },
  headers: { 'X-Custom-Header': 'value' },
  onProgress: (p) => console.log(`Uploading: ${p}%`),
});

if (result.success) {
  console.log('Response:', result.data);
}
```

---

### `saveBase64AsFile(options)`

Save a base64 string or data URI as a file. Perfect for handling base64 images, documents, or any binary data.

```javascript
import { saveBase64AsFile } from 'rn-file-toolkit';

// From data URI (auto-detects file extension)
const result = await saveBase64AsFile({
  base64Data: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUg...',
  fileName: 'photo.png',
  destination: 'documents', // 'downloads' | 'cache' | 'documents'
});

// From plain base64 string
const result = await saveBase64AsFile({
  base64Data: 'SGVsbG8gV29ybGQ=',
  fileName: 'hello.txt',
  destination: 'cache',
});

if (result.success) {
  console.log('File saved at:', result.filePath);
}
```

---

### `urlToBase64(options)`

Convert a web URL (image, video, gif, etc.) to base64 string. Perfect for converting remote media to base64 for local processing.

```javascript
import { urlToBase64 } from 'rn-file-toolkit';

const result = await urlToBase64({
  url: 'https://example.com/photo.jpg',
  headers: { Authorization: 'Bearer <token>' }, // optional
});

if (result.success) {
  console.log('Base64:', result.base64);
  console.log('Data URI:', result.dataUri);
  console.log('MIME Type:', result.mimeType); // e.g., 'image/jpeg'

  // Use in Image component
  // <Image source={{ uri: result.dataUri }} />
}
```

---

### `shareFile(options)`

Share a file with other apps using the native share dialog.

```javascript
import { shareFile } from 'rn-file-toolkit';

const result = await shareFile({
  filePath: '/path/to/document.pdf',
  title: 'Share Document', // Android only
  subject: 'Check this out', // Android only
});

if (result.success) {
  console.log('File shared successfully');
}
```

---

### `openFile(options)`

Open a file with the default app or app chooser.

```javascript
import { openFile } from 'rn-file-toolkit';

const result = await openFile({
  filePath: '/path/to/document.pdf',
  mimeType: 'application/pdf', // optional, auto-detected if not provided
});

if (result.success) {
  console.log('File opened');
}
```

---

### `unzip(sourcePath, destDir)` · `zip(sourcePath, destPath)`

Compress and extract ZIP archives natively — **no third-party library required**.

- **Android** uses `java.util.zip` (built into the Android SDK, every API level).
- **iOS** uses `zlib` (system framework, linked via `s.libraries = 'z'` in the podspec — ships on every iPhone/iPad).

```javascript
import { download, unzip, zip } from 'rn-file-toolkit';

// ── Unzip a downloaded archive ──────────────────────────────────────────────
const dl = await download({
  url: 'https://example.com/assets.zip',
  destination: 'cache',
});

if (dl.success) {
  const result = await unzip(
    dl.filePath, // absolute path to the .zip file
    '/path/to/output-folder' // destination directory (created if it doesn't exist)
  );

  if (result.success) {
    console.log('Destination:', result.destDir);
    console.log('Extracted files:', result.files);
    // result.files → ['/path/to/output-folder/image.png', ...]
  } else {
    console.log('Error:', result.error);
  }
}

// ── Zip a single file ───────────────────────────────────────────────────────
const zipResult = await zip(
  '/path/to/document.pdf', // source file
  '/path/to/document.zip' // output archive path
);

if (zipResult.success) {
  console.log('Archive created at:', zipResult.zipPath);
}

// ── Zip an entire directory ─────────────────────────────────────────────────
const dirResult = await zip(
  '/path/to/my-folder', // source directory
  '/path/to/my-folder.zip' // output archive path
);
```

> **Notes:**
>
> - `unzip` auto-creates the destination directory including any intermediate folders.
> - `unzip` on Android protects against [zip-slip attacks](https://snyk.io/research/zip-slip-vulnerability) by validating each entry path.
> - `zip` supports both single files and entire directory trees (recursive).
> - Both functions run on a background thread and never block the JS thread.
> - Supported compression methods: **Deflate** (method 8) and **Store** (method 0) — the two methods used by virtually every ZIP file.

---

### Pause / Resume / Cancel

```javascript
import { pauseDownload, resumeDownload, cancelDownload } from 'rn-file-toolkit';

await pauseDownload(downloadId);
await resumeDownload(downloadId);
await cancelDownload(downloadId);
```

---

### Cache Management

```javascript
import { getCachedFiles, deleteFile, clearCache } from 'rn-file-toolkit';

// List all files in the cache/documents folders
const { files } = await getCachedFiles();

// Delete a specific file
await deleteFile('/path/to/file.pdf');

// Clear all managed files
await clearCache();
```

---

### `fs` (filesystem namespace)

Use built-in file system helpers without adding another dependency.

```javascript
import { fs } from 'rn-file-toolkit';

await fs.exists('/path/to/file.pdf'); // → true/false

await fs.stat('/path/to/file.pdf');
// → { path, name, size, modified, isDir }

await fs.readFile('/path/to/file.txt'); // utf8 by default
await fs.readFile('/path/to/file.bin', 'base64');

await fs.writeFile('/path/to/file.txt', 'hello');
await fs.writeFile('/path/to/file.bin', 'SGVsbG8=', 'base64');

await fs.copyFile('/src/file.pdf', '/dst/file.pdf');
await fs.moveFile('/src/file.pdf', '/dst/file.pdf');
await fs.deleteFile('/path/to/file.pdf');

await fs.mkdir('/path/to/folder');
await fs.ls('/path/to/folder'); // → string[]
```

> `readFile` / `writeFile` support encodings: `'utf8'` (default) and `'base64'`.

---

## Use Cases

### Download from URLs

Perfect for downloading files from remote servers with progress tracking, background support, and resume capability.

### Convert URLs to Base64

Convert remote media (images, videos, gifs) to base64 strings for:

- Display in Image components without downloading to disk
- Inline embedding in HTML/emails
- Upload to APIs requiring base64 format
- Cross-platform data transfer

### Save Base64/Data URIs

Convert base64-encoded data (like images from canvas, camera, or API responses) directly to files:

- Canvas-generated images (`canvas.toDataURL()`)
- Camera/photo library base64 outputs
- API responses with base64-encoded files
- Email attachments in base64 format

---

## Type Reference

| Type                 | Fields                                                                                                                                           |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `DownloadOptions`    | `url`, `fileName?`, `background?`, `headers?`, `destination?`, `notificationTitle?`, `notificationDescription?`, `checksum?`, `onProgress?`, `retry?`, `queue?`, `priority?` |
| `ProgressInfo`       | `percent`, `bytesDownloaded`, `totalBytes`, `speedBps`, `etaSeconds`                                                                             |
| `RetryOptions`       | `attempts`, `delay?`, `onRetry?`                                                                                                                 |
| `QueueOptions`       | `maxConcurrent?`                                                                                                                                 |
| `QueueStatus`        | `active`, `pending`, `maxConcurrent`                                                                                                             |
| `DownloadStatus`     | `'idle' \| 'downloading' \| 'paused' \| 'done' \| 'error'`                                                                                       |
| `UseDownloadReturn`  | `start`, `pause`, `resume`, `cancel`, `status`, `progress`, `result`, `downloadId`                                                               |
| `FsEncoding`         | `'utf8' \| 'base64'`                                                                                                                             |
| `FsStat`             | `path`, `name`, `size`, `modified`, `isDir`                                                                                                      |
| `FsApi`              | `exists`, `stat`, `readFile`, `writeFile`, `copyFile`, `moveFile`, `deleteFile`, `mkdir`, `ls`                                                   |
| `UploadOptions`      | `url`, `filePath`, `fieldName?`, `headers?`, `parameters?`, `onProgress?`                                                                        |
| `SaveBase64Options`  | `base64Data`, `fileName?`, `destination?`                                                                                                        |
| `UrlToBase64Options` | `url`, `headers?`                                                                                                                                |
| `ShareFileOptions`   | `filePath`, `title?`, `subject?`                                                                                                                 |
| `OpenFileOptions`    | `filePath`, `mimeType?`                                                                                                                          |
| `DownloadResult`     | `success`, `filePath?`, `downloadId?`, `error?`                                                                                                  |
| `UploadResult`       | `success`, `status?`, `data?`, `error?`                                                                                                          |
| `UnzipResult`        | `success`, `destDir?`, `files?`, `error?`                                                                                                        |
| `ZipResult`          | `success`, `zipPath?`, `error?`                                                                                                                  |
| `SaveBase64Result`   | `success`, `filePath?`, `error?`                                                                                                                 |
| `UrlToBase64Result`  | `success`, `base64?`, `mimeType?`, `dataUri?`, `error?`                                                                                          |
| `ShareFileResult`    | `success`, `completed?`, `error?`                                                                                                                |
| `OpenFileResult`     | `success`, `error?`                                                                                                                              |
| `Checksum`           | `hash`, `algorithm: 'md5' \| 'sha1' \| 'sha256'`                                                                                                 |

---

## Articles & Resources

- [**I Got Tired of React Native File Downloads Being a Mess — So I Built rn-file-toolkit**](https://medium.com/@chavanrohit413/i-got-tired-of-react-native-file-downloads-being-a-mess-so-i-built-rn-file-toolkit-29b7a8b5c743) — Deep dive into the problems with existing solutions and how rn-file-toolkit solves them

---

## Links

- [GitHub](https://github.com/chavan-labs/rn-file-toolkit)
- [npm](https://www.npmjs.com/package/rn-file-toolkit)

---

_Made natively for the community 🤝 by Rohit Chavan_
