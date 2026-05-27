# API Overview

## Downloads

- `download(options)`
- `setQueueOptions(options)`
- `useDownload()`

Key concepts:

- queueing
- retries
- progress callbacks
- pause/resume/cancel

## Uploads

- `upload(options)`

Supports multipart upload with progress callback.

## File system

Under `fs`:

- `exists(path)`
- `stat(path)`
- `readFile(path, encoding)`
- `writeFile(path, data, encoding)`
- `mkdir(path)`
- `ls(path)`
- `copyFile(from, to)`
- `moveFile(from, to)`
- `deleteFile(path)`

## Archive

- `zip(sourcePath, outZipPath)`
- `unzip(zipPath, destinationPath)`

## Utilities

- `saveBase64AsFile(options)`
- `urlToBase64(options)`
- `shareFile(options)`
- `openFile(options)`
