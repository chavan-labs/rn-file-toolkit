<div align="center">
  <h1>rn-file-toolkit 🗂️</h1>
  <p><b>The ultimate, unified native file management toolkit for React Native & Expo</b></p>
  
  [![npm version](https://img.shields.io/npm/v/rn-file-toolkit.svg?style=for-the-badge&color=success)](https://www.npmjs.com/package/rn-file-toolkit)
  [![npm downloads](https://img.shields.io/npm/dt/rn-file-toolkit.svg?style=for-the-badge)](https://www.npmjs.com/package/rn-file-toolkit)
  [![TypeScript](https://img.shields.io/badge/TypeScript-Ready-blue.svg?style=for-the-badge&logo=typescript)](https://www.typescriptlang.org/)
  [![platforms](https://img.shields.io/badge/Platforms-iOS%20%7C%20Android-lightgrey.svg?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/chavan-labs/rn-file-toolkit)
  [![license](https://img.shields.io/npm/l/rn-file-toolkit.svg?style=for-the-badge)](https://github.com/chavan-labs/rn-file-toolkit/blob/main/LICENSE)
</div>

---

**rn-file-toolkit** is the modern replacement for legacy file libraries. Download, upload, manage queues, extract archives, and interact with the filesystem—all powered by pure native implementations (Kotlin + Swift) with **zero third-party dependencies**.

⭐ **Star this repo if you find it useful to help others discover it!**

## 📖 Table of Contents
- [Why rn-file-toolkit?](#-why-rn-file-toolkit)
- [Why not Expo FileSystem?](#-why-not-expo-filesystem)
- [Installation](#-installation)
- [Quick Start: `useDownload`](#-quick-start-usedownload)
- [Core APIs](#-core-apis)
  - [Background Downloads](#background-downloads)
  - [Multipart Uploads](#multipart-uploads)
  - [File System (FS)](#file-system-fs)
  - [Zip & Unzip Archives](#zip--unzip-archives)
  - [Media & Utilities](#media--utilities)
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

## 🤔 Why not Expo FileSystem?

Many developers looking for an **"expo-file-system alternative"** or a **"better react native download manager"** come here. While Expo FileSystem is a great tool for basic file operations, `rn-file-toolkit` is built specifically to handle complex, real-world file management scenarios:

- **Queueing & Concurrency:** Built-in smart queueing allows you to cap concurrent downloads and set priorities without writing complex JavaScript wrappers.
- **Native Download/Upload Managers:** We hook directly into OS-level managers (`URLSession` on iOS, `DownloadManager` on Android) for maximum reliability and battery efficiency.
- **Auto-Retries & Resiliency:** Native implementations handle network drops with exponential backoff and HTTP resume automatically.
- **Multipart Uploads:** Robust, memory-efficient multipart uploads for large media are built right in.
- **Drop-in React Hooks:** Provides a `useDownload` hook out-of-the-box for instant progress tracking, speed, ETA, and state controls.
- **Background Persistence:** Downloads and uploads survive app suspension and backgrounding, automatically re-attaching when the app resumes.

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

*(Optional) If you are not using Expo or an auto-linking setup, run `pod install` in your `ios` directory.*

---

## ⚡ Quick Start: `useDownload`

The easiest way to manage a download inside a React component. Get status, rich progress (with speed & ETA), and full controls instantly.

```tsx
import React from 'react';
import { View, Text, Button } from 'react-native';
import { useDownload } from 'rn-file-toolkit';

export default function DownloadScreen() {
  const { start, pause, resume, cancel, status, progress, result } = useDownload();

  return (
    <View style={{ padding: 20 }}>
      <Button 
        title="Start Download" 
        onPress={() => start({ 
          url: 'https://example.com/large-video.mp4', 
          destination: 'documents' 
        })} 
      />

      {status === 'downloading' && progress && (
        <View style={{ marginTop: 20 }}>
          <Text>Progress: {progress.percent.toFixed(1)}%</Text>
          <Text>Speed: {(progress.speedBps / 1024 / 1024).toFixed(2)} MB/s</Text>
          <Text>ETA: {progress.etaSeconds.toFixed(0)} seconds</Text>
          <View style={{ flexDirection: 'row', gap: 10, marginTop: 10 }}>
            <Button title="Pause" onPress={pause} />
            <Button title="Cancel" onPress={cancel} color="red" />
          </View>
        </View>
      )}

      {status === 'paused' && <Button title="Resume" onPress={resume} />}
      {status === 'done' && <Text style={{ color: 'green' }}>✅ Saved: {result?.filePath}</Text>}
      {status === 'error' && <Text style={{ color: 'red' }}>❌ Error: {result?.error}</Text>}
    </View>
  );
}
```

---

## 🛠️ Core APIs

### Background Downloads
For programmatic, queue-aware background downloads outside of React components.

```typescript
import { download, setQueueOptions } from 'rn-file-toolkit';

// Optimize global concurrency
setQueueOptions({ maxConcurrent: 3 });

const result = await download({
  url: 'https://example.com/file.pdf',
  destination: 'documents', // 'downloads' | 'cache' | 'documents'
  queue: true,              // Join the managed queue
  priority: 'high',         // 'high' | 'normal'
  retry: { attempts: 3, delay: 1000 },
  onProgress: (p) => console.log(`${p.percent.toFixed(1)}% downloaded`),
});
```

### Multipart Uploads
Robust, memory-efficient multipart file uploading for large media or documents.

```typescript
import { upload } from 'rn-file-toolkit';

const result = await upload({
  url: 'https://api.example.com/v1/upload',
  filePath: '/path/to/local/image.jpg',
  fieldName: 'file',
  parameters: { userId: '123', folder: 'avatars' },
  onProgress: (percent) => console.log(`Uploading: ${percent}%`),
});
```

### File System (FS)
Perform native filesystem operations securely.

```typescript
import { fs } from 'rn-file-toolkit';

// Check & Inspect
const exists = await fs.exists('/path/to/data.json');
const stats = await fs.stat('/path/to/data.json'); // { size, modified, isDir }

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

### Zip & Unzip Archives
Compress and extract archives directly on the device.

```typescript
import { unzip, zip } from 'rn-file-toolkit';

// Extract a downloaded zip
await unzip('/path/to/bundle.zip', '/path/to/extract-folder');

// Compress user data before uploading
await zip('/path/to/user-data-folder', '/path/to/backup.zip');
```

### Media & Utilities
Helpful tools for sharing, opening, and encoding files.

```typescript
import { saveBase64AsFile, urlToBase64, shareFile, openFile } from 'rn-file-toolkit';

// Base64 to File
await saveBase64AsFile({ 
  base64Data: 'data:image/png;base64,...', 
  destination: 'documents',
  fileName: 'image.png'
});

// URL to Base64 (Great for caching small images)
const b64 = await urlToBase64({ url: 'https://example.com/icon.png' });

// Native Share Sheet
await shareFile({ filePath: '/path/to/report.pdf' });

// Open with default system app
await openFile({ filePath: '/path/to/report.pdf', mimeType: 'application/pdf' });
```

---

## 📚 API Reference

| Interface | Key Properties | Description |
| :--- | :--- | :--- |
| `DownloadOptions` | `url`, `destination`, `queue`, `retry`, `onProgress` | Configuration for downloading a file. |
| `UploadOptions` | `url`, `filePath`, `fieldName`, `parameters`, `onProgress` | Configuration for multipart uploads. |
| `ProgressInfo` | `percent`, `bytesDownloaded`, `speedBps`, `etaSeconds` | Rich real-time progress payload. |
| `UseDownloadReturn` | `start`, `pause`, `resume`, `cancel`, `status`, `progress` | Hook state and control methods. |
| `FsStat` | `size`, `modified`, `isDir` | Output of the filesystem `stat` method. |

*For advanced types and detailed parameter documentation, please refer to the source TypeScript definitions.*

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
