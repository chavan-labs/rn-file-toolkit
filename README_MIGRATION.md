# ⚠️ Migrating from `rn-downloader` to `rn-file-toolkit`

The `rn-downloader` package has been rebranded to **`rn-file-toolkit`**. This new version is fully compatible but includes significant upgrades like a complete Filesystem API, Zip/Unzip support, and managed queues.

## Migration Guide

To migrate to the new package, follow these steps:

### 1. Uninstall the old package
```bash
npm uninstall rn-downloader
# or
yarn remove rn-downloader
```

### 2. Install the new package
```bash
npm install rn-file-toolkit
# or
yarn add rn-file-toolkit
```

### 3. Update your imports
Simply replace all occurrences of `rn-downloader` with `rn-file-toolkit` in your code:

```diff
- import { download } from 'rn-downloader';
+ import { download } from 'rn-file-toolkit';
```

## Why the change?
As the library grew, it became much more than just a downloader. It now supports:
- 📂 **Full File System APIs** (`ls`, `stat`, `mkdir`, `readFile`, `writeFile`, etc.)
- 📤 **Multipart Uploads**
- 🏗️ **Managed Download Queues** (cap concurrency and set priorities)
- 🔗 **Base64 & Data URI conversions**
- 📤 **Native Sharing & File Opening**
- 📦 **Native Zip & Unzip** (with zero third-party dependencies)

---
*If you have any issues during migration, please open an issue on the new [GitHub repository](https://github.com/chavan-labs/rn-file-toolkit).*
