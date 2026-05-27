# Troubleshooting

This page helps you diagnose common issues while using `rn-file-toolkit` in your app.

## 1) Download returns `success: false`

### Common causes

- URL is invalid or expired
- server rejects headers/auth
- destination directory is not writable
- network is unavailable

### What to check

- validate URL in browser/Postman
- pass required auth headers in `download({ headers })`
- try `destination: 'cache'` first to isolate permission/path issues
- enable retry:

```ts
retry: { attempts: 3, delay: 1000 }
```

## 2) Progress callback is not firing

### Common causes

- missing `onProgress` callback in options
- operation completes too quickly on small files
- wrong `downloadId` used in app logic

### What to check

- pass `onProgress` directly in the same `download()` call
- test with larger file size
- if using controls, keep a stable `downloadId`

## 3) Pause/resume/cancel does not work

Control APIs require the exact same `downloadId` used to start the download.

```ts
const id = 'my-download-1';
await download({ url, downloadId: id });
await pauseDownload(id);
```

If IDs differ, control calls target a different task.

## 4) Upload fails

### Common causes

- `filePath` does not exist
- server expects different `fieldName`
- missing auth headers

### What to check

- verify file exists before upload (`fs.exists(path)`)
- confirm server contract (`fieldName`, form parameters)
- inspect server response code in `UploadResult.status`

## 5) `openFile()` fails

Possible reason: no app installed that can handle the MIME type.

Try passing an explicit MIME type:

```ts
await openFile({ filePath, mimeType: 'application/pdf' });
```

## 6) `shareFile()` opens but user cancels

This is normal behavior. Treat it as a user choice, not an error.

## 7) File read/write errors

### Common causes

- invalid path
- wrong encoding (`utf8` vs `base64`)

### What to check

- check existence first with `fs.exists(path)`
- use matching encoding for write/read pair

## 8) Zip/unzip fails

### Common causes

- source path does not exist
- destination path is invalid
- corrupted zip

### What to check

- verify source with `fs.exists(sourcePath)`
- unzip into a directory you can write to

## 9) Expo app error with native module not found

`rn-file-toolkit` requires native build support.

- ❌ Expo Go: not supported
- ✅ Custom dev client / EAS build: supported

If using Expo, rebuild the native app after installing the package.
