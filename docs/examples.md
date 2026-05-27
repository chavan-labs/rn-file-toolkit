# Copy-Paste Examples

## 1) Simple download

```ts
import { download } from 'rn-file-toolkit';

const result = await download({
  url: 'https://example.com/file.pdf',
  destination: 'documents',
});

if (result.success) {
  console.log('Saved at:', result.filePath);
} else {
  console.log('Error:', result.error);
}
```

## 2) Download with progress + retry

```ts
import { download } from 'rn-file-toolkit';

const result = await download({
  url: 'https://example.com/video.mp4',
  destination: 'downloads',
  retry: { attempts: 3, delay: 1000 },
  onProgress: (p) => {
    console.log(`Progress: ${p.percent.toFixed(1)}%`);
    console.log(`Speed: ${(p.speedBps / 1024 / 1024).toFixed(2)} MB/s`);
    console.log(`ETA: ${Math.ceil(p.etaSeconds)}s`);
  },
});

console.log(result);
```

## 3) Queued downloads with concurrency

```ts
import { download, setQueueOptions, getQueueStatus } from 'rn-file-toolkit';

setQueueOptions({ maxConcurrent: 2 });

const urls = [
  'https://example.com/a.zip',
  'https://example.com/b.zip',
  'https://example.com/c.zip',
];

const results = await Promise.all(
  urls.map((url) =>
    download({
      url,
      destination: 'downloads',
      queue: true,
      priority: 'normal',
    })
  )
);

console.log('Queue status:', getQueueStatus());
console.log('Results:', results);
```

## 4) Pause, resume, and cancel

```ts
import {
  download,
  pauseDownload,
  resumeDownload,
  cancelDownload,
} from 'rn-file-toolkit';

const id = 'report-2026-05-27';

await download({
  url: 'https://example.com/report.pdf',
  destination: 'documents',
  downloadId: id,
});

await pauseDownload(id);
await resumeDownload(id);
// await cancelDownload(id);
```

## 5) Hook-based download screen

```tsx
import React from 'react';
import { View, Text, Button } from 'react-native';
import { useDownload } from 'rn-file-toolkit';

export default function DownloadScreen() {
  const { start, pause, resume, cancel, status, progress, result } =
    useDownload();

  return (
    <View style={{ padding: 16 }}>
      <Button
        title="Start Download"
        onPress={() =>
          start({
            url: 'https://example.com/manual.pdf',
            destination: 'documents',
          })
        }
      />

      <Text>Status: {status}</Text>
      {progress && <Text>Progress: {progress.percent.toFixed(1)}%</Text>}

      {status === 'downloading' && (
        <>
          <Button title="Pause" onPress={pause} />
          <Button title="Cancel" onPress={cancel} />
        </>
      )}
      {status === 'paused' && <Button title="Resume" onPress={resume} />}

      {result?.success && <Text>Saved: {result.filePath}</Text>}
      {!result?.success && result?.error && <Text>Error: {result.error}</Text>}
    </View>
  );
}
```

## 6) Multipart upload

```ts
import { upload } from 'rn-file-toolkit';

const res = await upload({
  url: 'https://api.example.com/upload',
  filePath: '/absolute/path/to/photo.jpg',
  fieldName: 'file',
  parameters: { userId: '42' },
  headers: { Authorization: 'Bearer <token>' },
  onProgress: (percent) => {
    console.log(`Upload ${percent.toFixed(1)}%`);
  },
});

console.log(res);
```

## 7) Filesystem basics

```ts
import { fs } from 'rn-file-toolkit';

await fs.mkdir('/tmp/demo');
await fs.writeFile('/tmp/demo/hello.txt', 'Hello world', 'utf8');

const exists = await fs.exists('/tmp/demo/hello.txt');
const text = await fs.readFile('/tmp/demo/hello.txt', 'utf8');
const stat = await fs.stat('/tmp/demo/hello.txt');
const entries = await fs.ls('/tmp/demo');

console.log({ exists, text, stat, entries });
```

## 8) Base64 from URL and save as file

```ts
import { urlToBase64, saveBase64AsFile } from 'rn-file-toolkit';

const b64 = await urlToBase64({
  url: 'https://example.com/logo.png',
});

if (b64.success && b64.base64) {
  const saved = await saveBase64AsFile({
    base64Data: b64.base64,
    fileName: 'logo.png',
    destination: 'documents',
  });

  console.log(saved);
}
```

## 9) Open and share file

```ts
import { openFile, shareFile } from 'rn-file-toolkit';

const filePath = '/absolute/path/to/invoice.pdf';

await openFile({ filePath, mimeType: 'application/pdf' });
await shareFile({ filePath, title: 'Invoice', subject: 'Invoice PDF' });
```

## 10) Zip and unzip

```ts
import { zip, unzip } from 'rn-file-toolkit';

const zipRes = await zip('/tmp/demo', '/tmp/demo.zip');
if (zipRes.success) {
  const unzipRes = await unzip('/tmp/demo.zip', '/tmp/demo_unzipped');
  console.log(unzipRes);
}
```

## 11) Event subscriptions

```ts
import {
  onDownloadComplete,
  onDownloadError,
  onDownloadRetry,
  onUploadProgress,
} from 'rn-file-toolkit';

const offComplete = onDownloadComplete((event) =>
  console.log('complete', event)
);
const offError = onDownloadError((event) => console.log('error', event));
const offRetry = onDownloadRetry((event) => console.log('retry', event));
const offUpload = onUploadProgress((event) =>
  console.log('upload progress', event)
);

offComplete();
offError();
offRetry();
offUpload();
```

## 12) Minimal reusable error helper

```ts
export function assertSuccess<T extends { success: boolean; error?: string }>(
  res: T
): T {
  if (!res.success) {
    throw new Error(res.error || 'Operation failed');
  }
  return res;
}
```
