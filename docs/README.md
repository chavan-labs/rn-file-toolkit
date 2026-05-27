# rn-file-toolkit

`rn-file-toolkit` is a native file toolkit for React Native apps.

It helps you:

- download files with progress, retry, queueing, and pause/resume
- upload files with multipart form-data
- read/write/manage files with a simple FS API
- zip and unzip files
- convert URL ↔ Base64 helpers
- open and share files with native OS dialogs

## Platform support

| Platform                     | Support |
| ---------------------------- | ------- |
| Android                      | ✅      |
| iOS                          | ✅      |
| Expo Go                      | ❌      |
| Expo custom dev client / EAS | ✅      |

Because this package includes native code, **Expo Go is not supported**.

## Installation

```bash
npm install rn-file-toolkit
```

For iOS apps:

```bash
cd ios && pod install
```

## 30-second quick start

```tsx
import { download } from 'rn-file-toolkit';

const result = await download({
  url: 'https://example.com/manual.pdf',
  destination: 'documents',
});

if (result.success) {
  console.log('Saved to:', result.filePath);
} else {
  console.log('Download failed:', result.error);
}
```

## Learn next

- [Getting Started](getting-started.md)
- [API Overview](api-overview.md)
- [Copy-Paste Examples](copy-paste-examples.md)
- [Guides](guides.md)
- [Troubleshooting](troubleshooting.md)
