import { TurboModuleRegistry, type TurboModule } from 'react-native';

export interface Spec extends TurboModule {
  download(options: Object): Promise<Object>;
  upload(options: Object): Promise<Object>;
  pauseDownload(downloadId: string): Promise<Object>;
  resumeDownload(downloadId: string): Promise<Object>;
  cancelDownload(downloadId: string): Promise<Object>;
  getCachedFiles(): Promise<Object>;
  deleteFile(filePath: string): Promise<Object>;
  clearCache(): Promise<Object>;
  getBackgroundDownloads(): Promise<Object>;
  exists(filePath: string): Promise<Object>;
  stat(filePath: string): Promise<Object>;
  readFile(filePath: string, encoding: string): Promise<Object>;
  writeFile(filePath: string, data: string, encoding: string): Promise<Object>;
  copyFile(fromPath: string, toPath: string): Promise<Object>;
  moveFile(fromPath: string, toPath: string): Promise<Object>;
  mkdir(dirPath: string): Promise<Object>;
  ls(dirPath: string): Promise<Object>;
  saveBase64AsFile(options: Object): Promise<Object>;
  urlToBase64(options: Object): Promise<Object>;
  shareFile(filePath: string, options: Object): Promise<Object>;
  openFile(filePath: string, mimeType: string): Promise<Object>;
  unzip(sourcePath: string, destDir: string): Promise<Object>;
  zip(sourcePath: string, destPath: string): Promise<Object>;
  df(): Promise<Object>;
  appendFile(filePath: string, data: string, encoding: string): Promise<Object>;
  hash(filePath: string, algorithm: string): Promise<Object>;
  getCookies(domain: string): Promise<Object>;
  clearCookies(domain: string): Promise<Object>;
  saveToMediaStore(options: Object): Promise<Object>;

  // Event emitter support
  addListener(eventName: string): void;
  removeListeners(count: number): void;
}

// `get` (not `getEnforcing`) so that merely importing this package cannot throw.
// `getEnforcing` raises an invariant at *import* time when the native side is not
// linked (Expo Go, web, a stale build, a missing pod install), which produces an
// opaque red screen with no hint about the cause. `src/index.tsx` wraps the result
// in a proxy that throws an actionable message on first use instead.
export default TurboModuleRegistry.get<Spec>('FileToolkit');
