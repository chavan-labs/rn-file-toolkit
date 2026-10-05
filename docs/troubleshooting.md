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
- if `percent` is `-1`, the server sent no `Content-Length`; show
  `bytesDownloaded` instead of a percentage

## 3) Pause/resume/cancel does not work

Control APIs require the exact same `downloadId` used to start the download.

```ts
const id = 'my-download-1';
const done = download({ url, downloadId: id }); // don't await yet
await pauseDownload(id);
await resumeDownload(id);
const result = await done;
```

If IDs differ, control calls target a different task. `download()` resolves
when the download finishes, so control calls made after `await download(...)`
target a task that no longer exists. A queued download that has not started
yet can be cancelled but not paused.

On iOS, a server that does not support resuming (no `Range` / `ETag` support)
produces no resume data when paused. The download then ends with
`error: 'PAUSE_FAILED_NO_RESUME_DATA'` (through `onDownloadError` for
background downloads) and must be started again.

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
- only stored and deflated entries are supported; encrypted entries and other
  compression methods (e.g. bzip2) return an error naming the entry
- on iOS, `zip()` cannot create archives larger than 4 GB or with more than
  65,535 entries (`ZIP64_NOT_SUPPORTED`); unzipping such archives works
- `zip()` fails if `destPath` equals the source or is a directory
- a corrupt, truncated or non-zip archive returns an error (for example
  `ZIP entry is corrupt: <name>` or `ZIP entry is truncated: <name>`) instead
  of a partial success. Files and folders created by the failed call are
  removed again; existing files are never deleted

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
app forwards the system's completion handler to `rn-file-toolkit`. Add this to
your `AppDelegate.swift` (no import needed):

```swift
func application(_ application: UIApplication,
                 handleEventsForBackgroundURLSession identifier: String,
                 completionHandler: @escaping () -> Void) {
  NotificationCenter.default.post(
    name: Notification.Name("RNFileToolkitBackgroundSessionEvents"),
    object: nil,
    userInfo: [
      "identifier": identifier,
      "completionHandler": (completionHandler as @convention(block) () -> Void) as AnyObject,
    ])
}
```

Objective-C `AppDelegate.mm` equivalent:

```objc
- (void)application:(UIApplication *)application
    handleEventsForBackgroundURLSession:(NSString *)identifier
                      completionHandler:(void (^)(void))completionHandler
{
  [[NSNotificationCenter defaultCenter]
      postNotificationName:@"RNFileToolkitBackgroundSessionEvents"
                    object:nil
                  userInfo:@{@"identifier": identifier,
                             @"completionHandler": [completionHandler copy]}];
}
```

The library moves the finished file to the requested `destination` /
`fileName` and verifies the `checksum` even if the app was terminated in the
meantime. `onDownloadComplete` / `onDownloadError` events that happen before
JS subscribes are kept (up to 100) and delivered when you subscribe — so
register `onDownloadComplete` / `onDownloadError` early (e.g. at app start) to
receive downloads that finished while the app was not running.

A background download whose task no longer exists on the next launch (for
example one that was paused when the app was terminated — iOS keeps its resume
data only in memory) is reported once through `onDownloadError` with
`error: 'DOWNLOAD_LOST'`. Start it again with `download()`.

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
