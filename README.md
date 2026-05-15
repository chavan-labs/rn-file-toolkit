# rn-file-toolkit

[![npm version](https://img.shields.io/npm/v/rn-file-toolkit.svg?style=flat-square)](https://www.npmjs.com/package/rn-file-toolkit)
[![npm downloads](https://img.shields.io/npm/dm/rn-file-toolkit.svg?style=flat-square)](https://www.npmjs.com/package/rn-file-toolkit)
[![license](https://img.shields.io/npm/l/rn-file-toolkit.svg?style=flat-square)](https://github.com/chavan-labs/rn-file-toolkit/blob/main/LICENSE)
[![TypeScript](https://img.shields.io/badge/TypeScript-Ready-blue.svg?style=flat-square)](https://www.typescriptlang.org/)
[![platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20Android-lightgrey.svg?style=flat-square)](https://github.com/chavan-labs/rn-file-toolkit)

The ultimate, unified file management library for React Native. Download, upload, manage queues, and interact with the filesystem—all powered by pure native implementations (Kotlin + Swift) with **zero third-party dependencies**.

⭐ **Star this repo if you found it useful!**

---

## Why rn-file-toolkit?
Most React Native file solutions are fragmented, bloated, or lack critical features like background queues or stable pause/resume. **rn-file-toolkit** gives you a unified, TurboModule-powered API utilizing OS-native download managers (`URLSession` on iOS, `DownloadManager` on Android) for reliable, battery-efficient file operations.

### ✨ Key Features
- **Drop-in `useDownload()` Hook:** Built-in state management (`status`, `progress`, `result`) and controls (`pause`, `resume`, `cancel`).
- **Background Downloads:** Survives app suspension with automatic re-attachment capabilities.
- **Smart Queueing:** Cap concurrency and set priorities (`high`/`normal`) without native configuration.
- **Resilient:** Auto-retries on network errors with exponential backoff and Range-based HTTP resume.
- **Zero-Dependency Zip/Unzip:** Uses native `java.util.zip` and iOS `zlib` for extracting/compressing files.
- **Rich File System API:** `readFile`, `writeFile`, `copyFile`, `moveFile`, `mkdir`, `ls`, `stat`, `exists`, and `deleteFile`.
- **Media Utilities:** Base64 encoding/decoding, URL to Base64 conversions, and native share/open dialogs.

---

## Installation

```sh
npm install rn-file-toolkit
```

---

## Quick Start: `useDownload` Hook

The easiest way to manage a download inside a React component. Get status, rich progress (with speed & ETA), and full controls out of the box.

```tsx
import { useDownload } from 'rn-file-toolkit';

function DownloadScreen() {
  const { start, pause, resume, cancel, status, progress, result } = useDownload();

  return (
    <View>
      <Button 
        title="Download" 
        onPress={() => start({ url: 'https://example.com/video.mp4', destination: 'documents' })} 
      />

      {status === 'downloading' && progress && (
        <View>
          <Text>{progress.percent.toFixed(1)}% ({(progress.speedBps / 1024).toFixed(1)} KB/s)</Text>
          <Text>ETA: {progress.etaSeconds.toFixed(0)}s</Text>
          <Button title="Pause" onPress={pause} />
          <Button title="Cancel" onPress={cancel} />
        </View>
      )}

      {status === 'paused' && <Button title="Resume" onPress={resume} />}
      {status === 'done' && <Text>✅ Saved to: {result?.filePath}</Text>}
      {status === 'error' && <Text>❌ {result?.error}</Text>}
    </View>
  );
}
```

---

## Core APIs

### `download(options)`
For programmatic, queue-aware background downloads.

```javascript
import { download, setQueueOptions } from 'rn-file-toolkit';

// Optional: Configure global concurrency queue
setQueueOptions({ maxConcurrent: 3 });

const result = await download({
  url: 'https://example.com/file.pdf',
  destination: 'documents', // 'downloads' | 'cache' | 'documents'
  queue: true, // Joins the managed queue
  priority: 'high', // 'high' | 'normal'
  retry: { attempts: 3, delay: 1000 },
  checksum: { hash: 'd41d8cd...', algorithm: 'md5' },
  onProgress: (p) => console.log(`${p.percent.toFixed(1)}%`),
});
```

### `upload(options)`
Robust, memory-efficient multipart file uploading.

```javascript
import { upload } from 'rn-file-toolkit';

const result = await upload({
  url: 'https://example.com/api/upload',
  filePath: '/path/to/my_image.jpg',
  fieldName: 'avatar',
  parameters: { userId: '123' },
  onProgress: (p) => console.log(`Uploading: ${p}%`),
});
```

### Filesystem (`fs`)
Perform native filesystem operations directly.

```javascript
import { fs } from 'rn-file-toolkit';

await fs.exists('/path/to/file.txt');
await fs.stat('/path/to/file.txt'); // { size, modified, isDir ... }
await fs.writeFile('/path/to/file.txt', 'hello', 'utf8'); // Supports 'base64'
await fs.copyFile('/src/file.txt', '/dst/file.txt');
await fs.mkdir('/path/to/folder');
const files = await fs.ls('/path/to/folder');
```

### Zip & Unzip
Compress and extract archives securely.

```javascript
import { unzip, zip } from 'rn-file-toolkit';

await unzip('/path/to/assets.zip', '/path/to/output-folder');
await zip('/path/to/document.pdf', '/path/to/document.zip');
```

### Media & Utilities

```javascript
import { saveBase64AsFile, urlToBase64, shareFile, openFile } from 'rn-file-toolkit';

// Convert base64 / Data URIs to files
await saveBase64AsFile({ base64Data: 'data:image/png;base64,...', destination: 'documents' });

// Fetch remote media as base64
await urlToBase64({ url: 'https://example.com/photo.jpg' });

// Share with native dialog
await shareFile({ filePath: '/path/to/document.pdf' });

// Open with default app
await openFile({ filePath: '/path/to/document.pdf', mimeType: 'application/pdf' });
```

---

## API Type Reference

| Type                 | Fields |
| -------------------- | ------ |
| `DownloadOptions`    | `url`, `fileName?`, `background?`, `headers?`, `destination?`, `notificationTitle?`, `notificationDescription?`, `checksum?`, `onProgress?`, `retry?`, `queue?`, `priority?` |
| `ProgressInfo`       | `percent`, `bytesDownloaded`, `totalBytes`, `speedBps`, `etaSeconds` |
| `RetryOptions`       | `attempts`, `delay?`, `onRetry?` |
| `QueueOptions`       | `maxConcurrent?` |
| `DownloadResult`     | `success`, `filePath?`, `downloadId?`, `error?` |
| `UploadOptions`      | `url`, `filePath`, `fieldName?`, `headers?`, `parameters?`, `onProgress?`, `uploadId?` |
| `UploadResult`       | `success`, `status?`, `data?`, `error?`, `uploadId?` |
| `UseDownloadReturn`  | `start`, `pause`, `resume`, `cancel`, `status`, `progress`, `result`, `downloadId` |
| `FsStat`             | `path`, `name`, `size`, `modified`, `isDir` |
| `UnzipResult`        | `success`, `destDir?`, `files?`, `error?` |
| `ZipResult`          | `success`, `zipPath?`, `error?` |

---

_Made natively for the community 🤝 by Rohit Chavan_
