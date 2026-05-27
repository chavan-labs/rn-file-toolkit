# Getting Started

## Installation

```bash
npm install rn-file-toolkit
```

For iOS, install pods in your app:

```bash
cd ios && pod install
```

## Basic download

```ts
import { download } from 'rn-file-toolkit';

const result = await download({
  url: 'https://example.com/file.pdf',
  destination: 'documents',
});

console.log(result.filePath);
```

## React hook usage

```tsx
import { useDownload } from 'rn-file-toolkit';

const { start, pause, resume, cancel, status, progress } = useDownload();
```

## Expo notes

This package includes native code, so use EAS/custom dev clients. Expo Go is not supported.
