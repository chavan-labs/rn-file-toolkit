# Getting Started

This page helps you integrate `rn-file-toolkit` into a real app quickly.

## 1) Install

```bash
npm install rn-file-toolkit
```

For iOS projects, run:

```bash
cd ios && pod install
```

## 2) Choose integration style

You can use either:

1. **Function-first API** (`download()`, `upload()`, `fs.*`) for service logic.
2. **Hook API** (`useDownload()`) for UI screens with live progress.

## 3) First download (function API)

```ts
import { download } from 'rn-file-toolkit';

const res = await download({
  url: 'https://example.com/brochure.pdf',
  destination: 'documents',
});

if (res.success) {
  console.log('Downloaded:', res.filePath);
} else {
  console.log('Download error:', res.error);
}
```

### What `destination` means

- `downloads` → device downloads area (best for user-visible files)
- `documents` → app documents directory
- `cache` → temporary cache directory

## 4) Download with UI progress (hook API)

```tsx
import React from 'react';
import { View, Text, Button } from 'react-native';
import { useDownload } from 'rn-file-toolkit';

export default function DownloadExample() {
  const { start, pause, resume, cancel, status, progress, result } =
    useDownload();

  return (
    <View style={{ padding: 16 }}>
      <Button
        title="Start"
        onPress={() =>
          start({
            url: 'https://example.com/video.mp4',
            destination: 'downloads',
            retry: { attempts: 3, delay: 1000 },
          })
        }
      />

      <Text>Status: {status}</Text>

      {progress && (
        <>
          <Text>Progress: {progress.percent.toFixed(1)}%</Text>
          <Text>
            Speed: {(progress.speedBps / 1024 / 1024).toFixed(2)} MB/s
          </Text>
          <Text>ETA: {Math.ceil(progress.etaSeconds)}s</Text>
        </>
      )}

      {status === 'downloading' && (
        <View style={{ gap: 8 }}>
          <Button title="Pause" onPress={pause} />
          <Button title="Cancel" onPress={cancel} />
        </View>
      )}

      {status === 'paused' && <Button title="Resume" onPress={resume} />}

      {result?.success && <Text>Saved: {result.filePath}</Text>}
      {!result?.success && result?.error && <Text>Error: {result.error}</Text>}
    </View>
  );
}
```

## 5) First upload

```ts
import { upload } from 'rn-file-toolkit';

const uploadRes = await upload({
  url: 'https://api.example.com/upload',
  filePath: '/absolute/path/to/photo.jpg',
  fieldName: 'file',
  parameters: { folder: 'avatars', userId: '42' },
  onProgress: (percent) => {
    console.log('Upload:', percent.toFixed(1), '%');
  },
});

if (!uploadRes.success) {
  console.log(uploadRes.error);
}
```

## 6) First filesystem action

```ts
import { fs } from 'rn-file-toolkit';

await fs.writeFile('/absolute/path/to/example.txt', 'Hello!', 'utf8');
const text = await fs.readFile('/absolute/path/to/example.txt', 'utf8');
console.log(text);
```

## Expo note

Use this package with **Expo custom dev clients** (`expo run:*` / EAS build).
It is not available in Expo Go.
