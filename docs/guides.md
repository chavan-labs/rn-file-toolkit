# Guides

This page contains practical usage patterns for package users.

## 1) Reliable downloads with retry + queue

Use queueing when your app can trigger many downloads in a short time.

```ts
import { download, setQueueOptions, getQueueStatus } from 'rn-file-toolkit';

setQueueOptions({ maxConcurrent: 3 });

const jobs = [
  'https://example.com/a.zip',
  'https://example.com/b.zip',
  'https://example.com/c.zip',
].map((url) =>
  download({
    url,
    destination: 'downloads',
    queue: true,
    priority: 'normal',
    retry: { attempts: 3, delay: 1000 },
  })
);

const results = await Promise.all(jobs);
console.log(getQueueStatus());
console.log(results);
```

Tip: assign `priority: 'high'` for user-triggered files that should start earlier.

## 2) Pause, resume, cancel by `downloadId`

```ts
import {
  download,
  pauseDownload,
  resumeDownload,
  cancelDownload,
} from 'rn-file-toolkit';

const downloadId = 'invoice-2026-05-27';

await download({
  url: 'https://example.com/invoice.pdf',
  destination: 'documents',
  downloadId,
});

await pauseDownload(downloadId);
await resumeDownload(downloadId);
// await cancelDownload(downloadId);
```

## 3) Background download pattern

Use `background: true` when long downloads may outlive screen lifetime.

```ts
import { download, getBackgroundDownloads } from 'rn-file-toolkit';

await download({
  url: 'https://example.com/big-video.mp4',
  destination: 'downloads',
  background: true,
  downloadId: 'big-video',
});

const active = await getBackgroundDownloads();
console.log(active);
```

## 4) Upload with metadata fields

```ts
import { upload } from 'rn-file-toolkit';

const res = await upload({
  url: 'https://api.example.com/v1/media/upload',
  filePath: '/absolute/path/to/video.mp4',
  fieldName: 'media',
  headers: {
    Authorization: 'Bearer <token>',
  },
  parameters: {
    albumId: 'summer-2026',
    visibility: 'private',
  },
  onProgress: (percent) => {
    console.log(`Uploading ${percent.toFixed(1)}%`);
  },
});

if (!res.success) console.log(res.error);
```

## 5) Read/write text and binary

```ts
import { fs } from 'rn-file-toolkit';

// text
await fs.writeFile('/tmp/note.txt', 'Hello user', 'utf8');
const note = await fs.readFile('/tmp/note.txt', 'utf8');

// base64 (binary)
await fs.writeFile('/tmp/image.b64', 'iVBORw0KGgoAAAANSUhEUgAA...', 'base64');
const b64 = await fs.readFile('/tmp/image.b64', 'base64');

console.log(note, b64.length);
```

## 6) File management flow

```ts
import { fs } from 'rn-file-toolkit';

await fs.mkdir('/tmp/reports');
await fs.copyFile('/tmp/a.txt', '/tmp/reports/a.txt');
await fs.moveFile('/tmp/reports/a.txt', '/tmp/reports/final-a.txt');

const files = await fs.ls('/tmp/reports');
const info = await fs.stat('/tmp/reports/final-a.txt');

console.log(files, info.size);
```

## 7) Zip + unzip flow

```ts
import { zip, unzip } from 'rn-file-toolkit';

const zipRes = await zip('/tmp/reports', '/tmp/reports.zip');
if (zipRes.success) {
  const unzipRes = await unzip('/tmp/reports.zip', '/tmp/reports_unzipped');
  console.log(unzipRes);
}
```

## 8) Base64 and sharing flow

```ts
import {
  urlToBase64,
  saveBase64AsFile,
  shareFile,
  openFile,
} from 'rn-file-toolkit';

const b64Res = await urlToBase64({
  url: 'https://example.com/logo.png',
});

if (b64Res.success && b64Res.base64) {
  const fileRes = await saveBase64AsFile({
    base64Data: b64Res.base64,
    fileName: 'logo.png',
    destination: 'documents',
  });

  if (fileRes.success && fileRes.filePath) {
    await openFile({ filePath: fileRes.filePath, mimeType: 'image/png' });
    await shareFile({ filePath: fileRes.filePath, title: 'Share logo' });
  }
}
```

## 9) Recommended error handling pattern

```ts
const res = await download({
  url: 'https://example.com/file.pdf',
  destination: 'documents',
});

if (!res.success) {
  // app-specific logging / UI message
  console.log('Operation failed:', res.error);
}
```

Use a consistent strategy:

- show readable UI message
- log raw error for diagnostics
- offer retry where possible
