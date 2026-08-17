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

## 10) `http://` downloads fail on Android

Android blocks cleartext (non-HTTPS) traffic by default from API 28 onwards. A
plain `http://` URL fails with `CLEARTEXT communication ... not permitted`.

- **Preferred:** use `https://`.
- **Bare React Native:** set `android:usesCleartextTraffic="true"` on the
  `<application>` tag in `android/app/src/main/AndroidManifest.xml`, or ship a
  network security config that allows only the hosts you need.
- **Expo:** add [`expo-build-properties`](https://docs.expo.dev/versions/latest/sdk/build-properties/)
  and set `android.usesCleartextTraffic: true`.

## 11) Pause / resume does not work for background downloads

Pause and resume are only available for **foreground** downloads
(`background: false`, the default).

- **Android** hands background downloads to the system `DownloadManager`, which
  exposes no pause/resume API. `pauseDownload()` resolves with
  `success: false` and an explanatory `error`. Use `cancelDownload()` to stop one.
- **iOS** can pause background downloads, because `NSURLSession` produces resume
  data.

## 12) Background downloads on iOS finish only while the app is open

iOS wakes the app to hand over a finished background transfer, but only if the
app forwards the system's completion handler. Add this to your `AppDelegate`:

```objc
- (void)application:(UIApplication *)application
    handleEventsForBackgroundURLSession:(NSString *)identifier
                      completionHandler:(void (^)(void))completionHandler
{
  // Keep the handler and call it once your session delegate reports it is done.
  self.backgroundSessionCompletionHandler = completionHandler;
}
```

Without it the download still completes, but `onDownloadComplete` may not fire
until the user next opens the app.

## 13) `getBackgroundDownloads()` returns different `status` values per platform

`status` is passed through from the platform and is **not** normalised:

- **Android** — `DownloadManager` status constants (`1` pending, `2` running,
  `4` paused, `8` successful, `16` failed).
- **iOS** — `NSURLSessionTask.state` (`0` running, `1` suspended, `2` cancelling,
  `3` completed).

Use `progress` and the `onDownloadComplete` / `onDownloadError` events for
portable logic.

## 14) The native module is missing in tests, on web, or during SSR

Importing `rn-file-toolkit` never throws on its own — the error is raised the
first time you call a method. Check availability before calling:

```ts
import { isAvailable, download } from 'rn-file-toolkit';

if (isAvailable) {
  await download({ url });
}
```

In Jest, mock the module rather than relying on the real native side.
