<div align="center">
  <h1>rn-file-toolkit 🗂️</h1>
  <p><b>The ultimate, unified native file management toolkit for React Native & Expo</b></p>
  
  [![npm version](https://img.shields.io/npm/v/rn-file-toolkit.svg?style=for-the-badge&color=success)](https://www.npmjs.com/package/rn-file-toolkit)
  [![npm downloads](https://img.shields.io/npm/dt/rn-file-toolkit.svg?style=for-the-badge)](https://www.npmjs.com/package/rn-file-toolkit)
  [![TypeScript](https://img.shields.io/badge/TypeScript-Ready-blue.svg?style=for-the-badge&logo=typescript)](https://www.typescriptlang.org/)
  [![platforms](https://img.shields.io/badge/Platforms-iOS%20%7C%20Android-lightgrey.svg?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/chavan-labs/rn-file-toolkit)
  [![license](https://img.shields.io/npm/l/rn-file-toolkit.svg?style=for-the-badge)](https://github.com/chavan-labs/rn-file-toolkit/blob/main/LICENSE)
  [![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg?style=for-the-badge)](https://makeapullrequest.com)
</div>

---

**rn-file-toolkit** is the modern replacement for legacy file libraries. Download, upload, manage queues, extract archives, and interact with the filesystem—all powered by pure native implementations (Kotlin + Swift) with **zero third-party dependencies**.

⭐ **Star this repo if you find it useful to help others discover it!**

## 📖 Table of Contents

- [Why rn-file-toolkit?](#-why-rn-file-toolkit)
- [Why not Expo FileSystem?](#-why-not-expo-filesystem)
- [Documentation Website](#-documentation-website)
- [Installation](#-installation)
- [Quick Start: `useDownload`](#-quick-start-usedownload)
- [Core APIs](#-core-apis)
  - [Background Downloads](#background-downloads)
  - [Download Controls](#download-controls)
  - [Multipart Uploads](#multipart-uploads)
  - [Queue Management](#queue-management)
  - [File System (FS)](#file-system-fs)
  - [Zip & Unzip Archives](#zip--unzip-archives)
  - [Cache Management](#cache-management)
  - [Media & Utilities](#media--utilities)
  - [Event Listeners](#event-listeners)
- [API Reference](#-api-reference)
- [Expo Support](#-expo-support)
- [Contributing](#-contributing)

---

## 🚀 Why rn-file-toolkit?

Most React Native file solutions (`rn-fetch-blob`, `react-native-fs`) are fragmented, lightly maintained, or lack modern features. **rn-file-toolkit** gives you a unified, **TurboModule-compatible** API utilizing OS-native managers (`URLSession` on iOS, `DownloadManager` on Android) for reliable, battery-efficient operations.

### ✨ Highlights

- 🪝 **Drop-in React Hooks:** Built-in state management (`useDownload`) for progress and controls.
- 📥 **Background Ready:** Downloads and uploads survive app suspension with automatic re-attachment.
- 🚦 **Smart Queueing:** Cap concurrency and set priorities without touching native code.
- 🛡️ **Resilient:** Auto-retries on network errors with exponential backoff and HTTP resume.
- 🗜️ **Zero-Dependency Zip:** Uses native `java.util.zip` and iOS `zlib`.
- 🗄️ **Rich File System API:** Comprehensive FS methods (`readFile`, `writeFile`, `copyFile`, `mkdir`, `stat`, etc.).
- 🛠️ **Expo Compatible:** Seamless integration with Expo custom dev clients.

---

## 🥊 How does it compare?

If you've been working with React Native for a while, you've probably used `rn-fetch-blob` or `react-native-fs`. While they were fantastic tools back in the day, they haven't aged well and often struggle with modern requirements like seamless Expo integration or background persistence. You might have also tried `expo-file-system`, which is great for the basics but starts to fall short when you need smart queueing or multipart uploads.

We built **rn-file-toolkit** because we were tired of stitching together multiple unmaintained libraries just to download a file reliably in the background while keeping the UI updated.

Here's how it stacks up against the crowd:

| Feature | `rn-file-toolkit` | `react-native-fs` & `rn-fetch-blob` | `expo-file-system` |
| :--- | :---: | :---: | :---: |
| **Background Persistence** | ✅ Yes | ⚠️ Spotty / Legacy | ✅ Yes |
| **Smart Queueing & Concurrency** | ✅ Built-in | ❌ Write your own | ❌ Write your own |
| **React Hooks (`useDownload`)** | ✅ Out-of-the-box | ❌ Manual | ❌ Manual |
| **Auto-Retries & Resumption** | ✅ Yes | ❌ Manual | ⚠️ Basic resume only |
| **Multipart Uploads** | ✅ Yes (Memory efficient) | ⚠️ Basic support | ✅ Yes |
| **Expo Support (Custom Dev Client)**| ✅ Seamless | ❌ Requires heavy config | ✅ Seamless |
| **Zero 3rd-party Dependencies** | ✅ Yes | ❌ Varies | ✅ Yes |
| **Active Maintenance** | ✅ Yes | ❌ Largely unmaintained | ✅ Yes |

We hook directly into OS-level managers (`URLSession` on iOS, `DownloadManager` on Android) to provide maximum reliability, battery efficiency, and zero headaches.

---

## 🌐 Documentation Website

Full docs are hosted on GitHub Pages:

https://chavan-labs.github.io/rn-file-toolkit/

---

## 📦 Installation

```bash
# npm
npm install rn-file-toolkit

# yarn
yarn add rn-file-toolkit

# pnpm
pnpm add rn-file-toolkit
```

_(Optional) If you are not using Expo or an auto-linking setup, run `pod install` in your `ios` directory._

---

## ⚡ Quick Start: `useDownload`

The easiest way to manage a download inside a React component. Get status, rich progress (with speed & ETA), and full controls instantly.

```tsx
import React from 'react';
import { View, Text, Button } from 'react-native';
import { useDownload } from 'rn-file-toolkit';

export default function DownloadScreen() {
  const { start, pause, resume, cancel, status, progress, result } =
    useDownload();

  return (
    <View style={{ padding: 20 }}>
      <Button
        title="Start Download"
        onPress={() =>
          start({
            url: 'https://example.com/large-video.mp4',
            destination: 'documents',
          })
        }
      />

      {status === 'downloading' && progress && (
        <View style={{ marginTop: 20 }}>
          <Text>Progress: {progress.percent.toFixed(1)}%</Text>
          <Text>
            Speed: {(progress.speedBps / 1024 / 1024).toFixed(2)} MB/s
          </Text>
          <Text>ETA: {progress.etaSeconds.toFixed(0)} seconds</Text>
          <View style={{ flexDirection: 'row', gap: 10, marginTop: 10 }}>
            <Button title="Pause" onPress={pause} />
            <Button title="Cancel" onPress={cancel} color="red" />
          </View>
        </View>
      )}

      {status === 'paused' && <Button title="Resume" onPress={resume} />}
      {status === 'done' && (
        <Text style={{ color: 'green' }}>✅ Saved: {result?.filePath}</Text>
      )}
      {status === 'error' && (
        <Text style={{ color: 'red' }}>❌ Error: {result?.error}</Text>
      )}
    </View>
  );
}
```

---

## 🛠️ Core APIs

### Background Downloads

For programmatic, queue-aware background downloads outside of React components.

```typescript
import { download } from 'rn-file-toolkit';

const result = await download({
  url: 'https://example.com/file.pdf',
  fileName: 'report.pdf', // Optional custom filename
  destination: 'documents', // 'downloads' | 'cache' | 'documents'
  background: true, // Survive app suspension
  headers: { Authorization: 'Bearer token' },
  queue: true, // Join the managed queue
  priority: 'high', // 'high' | 'normal'
  downloadId: 'my-unique-id', // Optional custom ID for tracking
  notificationTitle: 'Downloading report…', // Android notification
  notificationDescription: 'Please wait',
  checksum: { hash: 'abc123...', algorithm: 'sha256' }, // Verify integrity
  retry: {
    attempts: 3,
    delay: 1000,
    onRetry: (attempt, error) => console.warn(`Retry #${attempt}: ${error}`),
  },
  onProgress: (p) => console.log(`${p.percent.toFixed(1)}% downloaded`),
});

console.log(result.filePath); // Path to the downloaded file
```

### Download Controls

Pause, resume, or cancel any active download by its ID—works both inside and outside React components.

```typescript
import {
  download,
  pauseDownload,
  resumeDownload,
  cancelDownload,
} from 'rn-file-toolkit';

// Start a download with a known ID
const result = download({
  url: 'https://example.com/large-video.mp4',
  downloadId: 'video-1',
  destination: 'documents',
});

// Later… pause, resume, or cancel by ID
await pauseDownload('video-1');
await resumeDownload('video-1');
await cancelDownload('video-1');
```

### Multipart Uploads

Robust, memory-efficient multipart file uploading for large media or documents.

```typescript
import { upload } from 'rn-file-toolkit';

const result = await upload({
  url: 'https://api.example.com/v1/upload',
  filePath: '/path/to/local/image.jpg',
  fieldName: 'file',
  headers: { Authorization: 'Bearer token' },
  parameters: { userId: '123', folder: 'avatars' },
  uploadId: 'upload-1', // Optional custom ID for tracking
  onProgress: (percent) => console.log(`Uploading: ${percent}%`),
});

console.log(result.status); // HTTP status code
console.log(result.data); // Server response body
```

### Queue Management

Control download concurrency globally and inspect the queue state.

```typescript
import { setQueueOptions, getQueueStatus } from 'rn-file-toolkit';

// Set the maximum number of simultaneous downloads
setQueueOptions({ maxConcurrent: 3 });

// Inspect the queue at any time
const status = getQueueStatus();
console.log(status.active); // Currently downloading
console.log(status.pending); // Waiting in queue
console.log(status.maxConcurrent); // Concurrency cap
```

You can also retrieve all downloads currently running in the background (useful after app re-launch):

```typescript
import { getBackgroundDownloads } from 'rn-file-toolkit';

const active = await getBackgroundDownloads();
console.log(active); // Array of background download descriptors
```

### File System (FS)

Perform native filesystem operations securely. All methods are available both as the namespaced `fs` object and as standalone named exports.

```typescript
import { fs } from 'rn-file-toolkit';

// Check & Inspect
const exists = await fs.exists('/path/to/data.json');
const stats = await fs.stat('/path/to/data.json'); // { path, name, size, modified, isDir }

// Read & Write
await fs.writeFile('/path/to/data.txt', 'Hello World', 'utf8'); // Also supports 'base64'
const content = await fs.readFile('/path/to/data.txt', 'utf8');

// Manage Folders & Files
await fs.mkdir('/path/to/new_folder');
const files = await fs.ls('/path/to/new_folder');
await fs.copyFile('/path/src.txt', '/path/dest.txt');
await fs.moveFile('/path/old.txt', '/path/new.txt');
await fs.deleteFile('/path/unwanted.txt');
```

> **Tip:** You can also import each FS method individually:
> ```typescript
> import { exists, stat, readFile, writeFile, copyFile, moveFile, deleteFile, mkdir, ls } from 'rn-file-toolkit';
> ```

### Zip & Unzip Archives

Compress and extract archives directly on the device using native `java.util.zip` (Android) and `zlib` (iOS).

```typescript
import { unzip, zip } from 'rn-file-toolkit';

// Extract a downloaded zip
const unzipResult = await unzip('/path/to/bundle.zip', '/path/to/extract-folder');
console.log(unzipResult.files); // List of extracted file paths

// Compress user data before uploading
const zipResult = await zip('/path/to/user-data-folder', '/path/to/backup.zip');
console.log(zipResult.zipPath); // Path to the created archive
```

### Cache Management

Inspect and clear files stored in the cache directory.

```typescript
import { getCachedFiles, clearCache } from 'rn-file-toolkit';

// List all cached files with metadata
const cache = await getCachedFiles();
cache.files?.forEach((f) => {
  console.log(f.fileName, f.filePath, f.size, f.modifiedAt);
});

// Wipe the entire cache directory
await clearCache();
```

### Media & Utilities

Helpful tools for sharing, opening, and encoding files.

```typescript
import {
  saveBase64AsFile,
  urlToBase64,
  shareFile,
  openFile,
} from 'rn-file-toolkit';

// Base64 to File (accepts raw base64 or data URIs)
await saveBase64AsFile({
  base64Data: 'data:image/png;base64,...',
  destination: 'documents',
  fileName: 'image.png',
});

// URL to Base64 (great for caching small images)
const b64 = await urlToBase64({
  url: 'https://example.com/icon.png',
  headers: { Authorization: 'Bearer token' }, // Optional
});
console.log(b64.mimeType); // e.g. 'image/png'
console.log(b64.dataUri); // Ready-to-use data URI string

// Native Share Sheet
await shareFile({
  filePath: '/path/to/report.pdf',
  title: 'Share report', // Optional
  subject: 'Monthly report', // Optional (email subject)
});

// Open with default system app
await openFile({
  filePath: '/path/to/report.pdf',
  mimeType: 'application/pdf',
});
```

### Event Listeners

Subscribe to global download and upload lifecycle events. Each listener returns an unsubscribe function.

```typescript
import {
  onDownloadComplete,
  onDownloadError,
  onDownloadRetry,
  onUploadProgress,
} from 'rn-file-toolkit';

// Fires when any download finishes successfully
const unsub1 = onDownloadComplete((event) => {
  console.log('Download done:', event);
});

// Fires when any download fails
const unsub2 = onDownloadError((event) => {
  console.error('Download failed:', event);
});

// Fires on each retry attempt (when retry is configured)
const unsub3 = onDownloadRetry((event) => {
  console.warn(`Retry #${event.attempt}:`, event.error);
});

// Fires on upload progress updates
const unsub4 = onUploadProgress((event) => {
  console.log(`Upload ${event.uploadId}: ${event.progress}%`);
});

// Clean up when done
unsub1();
unsub2();
unsub3();
unsub4();
```

---

## 📚 API Reference

### Types & Interfaces

| Interface | Key Properties | Description |
| :--- | :--- | :--- |
| `DownloadOptions` | `url`, `fileName`, `destination`, `background`, `headers`, `queue`, `priority`, `downloadId`, `checksum`, `retry`, `onProgress`, `notificationTitle`, `notificationDescription` | Full configuration for downloading a file. |
| `UploadOptions` | `url`, `filePath`, `fieldName`, `headers`, `parameters`, `uploadId`, `onProgress` | Configuration for multipart uploads. |
| `ProgressInfo` | `percent`, `bytesDownloaded`, `totalBytes`, `speedBps`, `etaSeconds` | Rich real-time download progress payload. |
| `DownloadResult` | `success`, `filePath`, `downloadId`, `error` | Result returned after a download completes. |
| `UploadResult` | `success`, `status`, `data`, `uploadId`, `error` | Result returned after an upload completes. |
| `ActionResult` | `success`, `error` | Generic result for actions like pause/resume/cancel. |
| `UseDownloadReturn` | `start`, `pause`, `resume`, `cancel`, `status`, `progress`, `result`, `downloadId` | Hook state and control methods. |
| `FsApi` | `exists`, `stat`, `readFile`, `writeFile`, `copyFile`, `moveFile`, `deleteFile`, `mkdir`, `ls` | Namespaced filesystem API. |
| `FsStat` | `path`, `name`, `size`, `modified`, `isDir` | Output of the filesystem `stat` method. |
| `FsEncoding` | `'utf8'` \| `'base64'` | Encoding used for read/write operations. |
| `QueueOptions` | `maxConcurrent` | Configuration for the download queue. |
| `QueueStatus` | `active`, `pending`, `maxConcurrent` | Snapshot of the current queue state. |
| `CachedFile` | `fileName`, `filePath`, `size`, `modifiedAt` | Metadata for a single cached file. |
| `CacheResult` | `success`, `files`, `error` | Result of `getCachedFiles()`. |
| `SaveBase64Options` | `base64Data`, `fileName`, `destination` | Options for saving a base64 string to a file. |
| `SaveBase64Result` | `success`, `filePath`, `error` | Result of `saveBase64AsFile()`. |
| `UrlToBase64Options` | `url`, `headers` | Options for converting a URL to base64. |
| `UrlToBase64Result` | `success`, `base64`, `mimeType`, `dataUri`, `error` | Result of `urlToBase64()`. |
| `ShareFileOptions` | `filePath`, `title`, `subject` | Options for the native share sheet. |
| `OpenFileOptions` | `filePath`, `mimeType` | Options for opening a file with the system default app. |
| `UnzipResult` | `success`, `destDir`, `files`, `error` | Result of `unzip()`. |
| `ZipResult` | `success`, `zipPath`, `error` | Result of `zip()`. |

### Exported Functions

| Function | Signature | Description |
| :--- | :--- | :--- |
| `download` | `(options: DownloadOptions) => Promise<DownloadResult>` | Download a file (supports queue, background, retries). |
| `upload` | `(options: UploadOptions) => Promise<UploadResult>` | Multipart upload a file. |
| `pauseDownload` | `(id: string) => Promise<ActionResult>` | Pause an active download by ID. |
| `resumeDownload` | `(id: string) => Promise<ActionResult>` | Resume a paused download by ID. |
| `cancelDownload` | `(id: string) => Promise<ActionResult>` | Cancel a download by ID. |
| `setQueueOptions` | `(options: QueueOptions) => void` | Set global queue concurrency. |
| `getQueueStatus` | `() => QueueStatus` | Get current queue state (active/pending counts). |
| `getBackgroundDownloads` | `() => Promise<any>` | Retrieve active background download descriptors. |
| `getCachedFiles` | `() => Promise<CacheResult>` | List all files in the cache directory. |
| `clearCache` | `() => Promise<ActionResult>` | Delete all cached files. |
| `deleteFile` | `(path: string) => Promise<ActionResult>` | Delete a single file by path. |
| `exists` | `(path: string) => Promise<boolean>` | Check if a file or directory exists. |
| `stat` | `(path: string) => Promise<FsStat>` | Get metadata for a file or directory. |
| `readFile` | `(path: string, encoding?: FsEncoding) => Promise<string>` | Read file contents as a string. |
| `writeFile` | `(path: string, data: string, encoding?: FsEncoding) => Promise<void>` | Write a string to a file. |
| `copyFile` | `(from: string, to: string) => Promise<void>` | Copy a file. |
| `moveFile` | `(from: string, to: string) => Promise<void>` | Move or rename a file. |
| `mkdir` | `(path: string) => Promise<void>` | Create a directory (recursive). |
| `ls` | `(path: string) => Promise<string[]>` | List directory contents. |
| `unzip` | `(src: string, dest: string) => Promise<UnzipResult>` | Extract a zip archive. |
| `zip` | `(src: string, dest: string) => Promise<ZipResult>` | Compress a folder into a zip archive. |
| `saveBase64AsFile` | `(options: SaveBase64Options) => Promise<SaveBase64Result>` | Save a base64 string as a file. |
| `urlToBase64` | `(options: UrlToBase64Options) => Promise<UrlToBase64Result>` | Fetch a URL and return its content as base64. |
| `shareFile` | `(options: ShareFileOptions) => Promise<ShareFileResult>` | Open the native share sheet for a file. |
| `openFile` | `(options: OpenFileOptions) => Promise<OpenFileResult>` | Open a file with the system default app. |
| `onDownloadComplete` | `(cb) => () => void` | Subscribe to download completion events. |
| `onDownloadError` | `(cb) => () => void` | Subscribe to download error events. |
| `onDownloadRetry` | `(cb) => () => void` | Subscribe to download retry events. |
| `onUploadProgress` | `(cb) => () => void` | Subscribe to upload progress events. |
| `useDownload` | `() => UseDownloadReturn` | React hook for managing a download with state. |
| `fs` | `FsApi` | Namespaced object grouping all filesystem methods. |

---

## 🎪 Expo Support

**rn-file-toolkit** works seamlessly with Expo custom development clients (EAS Build / `npx expo run:android` / `npx expo run:ios`). Since it contains native code, it is not compatible with Expo Go.

An Expo config plugin is included automatically. No extra configuration is needed in your `app.json` unless you want to customize permissions.

---

## 🤝 Contributing

Contributions are welcome! If you find a bug or want to request a feature, please [open an issue](https://github.com/chavan-labs/rn-file-toolkit/issues).

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

---

<div align="center">
  <i>Built with ❤️ for the React Native community by <a href="https://github.com/chavanRk">Rohit Chavan</a></i>
</div>
