import {
  download,
  setQueueOptions,
  getQueueStatus,
  session,
  cancelDownload,
  saveBase64AsFile,
  readFile,
  onDownloadComplete,
  onDownloadError,
} from '../index';
import type { DownloadOptions } from '../index';
import { NativeModules } from 'react-native';

/** Emits a native event to every listener registered through the mock emitter. */
declare const __emitNative: (event: string, payload: any) => void;
/** Number of listeners currently registered for an event. */
declare const __listenerCount: (event: string) => number;

// Mock the native module
jest.mock('react-native', () => {
  const callbacks: Record<string, Function[]> = {};

  const mockFileToolkit = {
    download: jest.fn().mockImplementation((opts) => {
      return Promise.resolve({
        success: true,
        filePath: `/mock/path/${opts.downloadId}`,
        downloadId: opts.downloadId,
      });
    }),
    addListener: jest.fn(),
    removeListeners: jest.fn(),
    clearCache: jest.fn().mockResolvedValue({ success: true }),
    deleteFile: jest.fn().mockResolvedValue({ success: true }),
  };

  (global as any).__emitNative = (event: string, payload: any) => {
    (callbacks[event] ?? []).slice().forEach((cb) => cb(payload));
  };
  (global as any).__listenerCount = (event: string) =>
    (callbacks[event] ?? []).length;

  return {
    Platform: { OS: 'ios', select: (spec: any) => spec.ios ?? spec.default },
    NativeModules: {
      FileToolkit: mockFileToolkit,
    },
    TurboModuleRegistry: {
      get: jest.fn().mockReturnValue(mockFileToolkit),
      getEnforcing: jest.fn().mockReturnValue(mockFileToolkit),
    },
    NativeEventEmitter: jest.fn().mockImplementation(() => ({
      addListener: jest.fn((event: string, cb: Function) => {
        if (!callbacks[event]) callbacks[event] = [];
        callbacks[event].push(cb);
        return {
          remove: jest.fn(() => {
            callbacks[event] = (callbacks[event] ?? []).filter((c) => c !== cb);
          }),
        };
      }),
      removeAllListeners: jest.fn(),
    })),
  };
});
const FileToolkit = NativeModules.FileToolkit as any;

describe('rn-file-toolkit JS Logic', () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  describe('DownloadQueue & getQueueStatus', () => {
    it('sets queue options and updates status', () => {
      setQueueOptions({ maxConcurrent: 2 });
      const status = getQueueStatus();
      expect(status.maxConcurrent).toBe(2);
      expect(status.active).toBe(0);
      expect(status.pending).toBe(0);
    });

    it('enqueues downloads and flushes properly', async () => {
      setQueueOptions({ maxConcurrent: 1 });

      // Delay the mock to test active/pending counts
      let resolveMock1: any;
      FileToolkit.download.mockImplementationOnce((opts: any) => {
        return new Promise((resolve) => {
          resolveMock1 = () =>
            resolve({
              success: true,
              filePath: '/mock/1',
              downloadId: opts.downloadId,
            });
        });
      });

      const opts1: DownloadOptions = { url: 'http://test.com/1', queue: true };
      const opts2: DownloadOptions = { url: 'http://test.com/2', queue: true };

      const p1 = download(opts1);
      const p2 = download(opts2);

      const status = getQueueStatus();
      expect(status.active).toBe(1);
      expect(status.pending).toBe(1);

      resolveMock1(); // finish first
      await p1;

      await p2;

      // Let microtask queue flush so .finally() in _flush executes
      await new Promise((r) => setTimeout(r, 0));

      const finalStatus = getQueueStatus();
      expect(finalStatus.active).toBe(0);
      expect(finalStatus.pending).toBe(0);
    });
  });

  describe('session management', () => {
    it('adds, gets, and clears sessions', async () => {
      const sessionId = 'test-session';
      session.add(sessionId, '/path/1');
      session.add(sessionId, '/path/2');

      const files = session.get(sessionId);
      expect(files).toEqual(['/path/1', '/path/2']);

      // Mock deleteFile just for session test
      FileToolkit.deleteFile = jest.fn().mockResolvedValue({ success: true });

      const result = await session.clear(sessionId);
      expect(result.success).toBe(true);
      expect(session.get(sessionId)).toEqual([]);
      expect(FileToolkit.deleteFile).toHaveBeenCalledTimes(2);
    });
  });

  describe('_generateId behavior', () => {
    it('generates unique download IDs automatically', async () => {
      const result1 = await download({ url: 'http://test.com/1' });
      const result2 = await download({ url: 'http://test.com/2' });

      expect(result1.downloadId).toBeDefined();
      expect(result2.downloadId).toBeDefined();
      expect(result1.downloadId).not.toEqual(result2.downloadId);

      // Check the native call
      expect(FileToolkit.download).toHaveBeenCalledTimes(2);
      const call1Args = FileToolkit.download.mock.calls[0][0];
      expect(call1Args.downloadId).toBeDefined();
    });
  });

  describe('progress listeners', () => {
    it('keeps onProgress alive after a background download is handed to the OS', async () => {
      FileToolkit.download.mockImplementationOnce((opts: any) =>
        // Background downloads resolve immediately, with no filePath yet.
        Promise.resolve({ success: true, downloadId: opts.downloadId })
      );

      const seen: number[] = [];
      const res = await download({
        url: 'http://test.com/big.zip',
        background: true,
        downloadId: 'bg-1',
        onProgress: (info) => seen.push(info.percent),
      });
      expect(res.success).toBe(true);

      __emitNative('onDownloadProgress', {
        downloadId: 'bg-1',
        progress: 42,
        bytesDownloaded: 42,
        totalBytes: 100,
      });
      expect(seen).toEqual([42]);

      // The terminal event tears the listeners back down.
      __emitNative('onDownloadComplete', {
        downloadId: 'bg-1',
        success: true,
        filePath: '/mock/big.zip',
      });
      expect(__listenerCount('onDownloadProgress')).toBe(0);
    });

    it('removes listeners as soon as a foreground download settles', async () => {
      await download({
        url: 'http://test.com/small.txt',
        downloadId: 'fg-1',
        onProgress: () => {},
      });
      expect(__listenerCount('onDownloadProgress')).toBe(0);
    });
  });

  describe('cancel and background bookkeeping', () => {
    const flush = () => new Promise((r) => setTimeout(r, 0));

    it('cancels a download that is still waiting in the queue', async () => {
      setQueueOptions({ maxConcurrent: 1 });
      FileToolkit.cancelDownload = jest.fn();
      let finishFirst: any;
      FileToolkit.download.mockImplementationOnce(
        (opts: any) =>
          new Promise((resolve) => {
            finishFirst = () =>
              resolve({
                success: true,
                filePath: '/f',
                downloadId: opts.downloadId,
              });
          })
      );
      const first = download({ url: 'http://t/1', queue: true });
      const queued = download({
        url: 'http://t/2',
        queue: true,
        downloadId: 'q-2',
      });

      expect(await cancelDownload('q-2')).toEqual({ success: true });
      expect(await queued).toEqual({
        success: false,
        downloadId: 'q-2',
        error: 'CANCELLED',
      });
      expect(FileToolkit.cancelDownload).not.toHaveBeenCalled();

      finishFirst();
      await first;
      await flush();
      // Only the first download ever reached native.
      expect(FileToolkit.download).toHaveBeenCalledTimes(1);
      expect(getQueueStatus()).toMatchObject({ active: 0, pending: 0 });
    });

    it('holds a queue slot until a background download finishes', async () => {
      setQueueOptions({ maxConcurrent: 1 });
      FileToolkit.download.mockImplementation((opts: any) =>
        Promise.resolve(
          opts.background
            ? { success: true, downloadId: opts.downloadId }
            : { success: true, filePath: '/f', downloadId: opts.downloadId }
        )
      );
      await download({
        url: 'http://t/a',
        queue: true,
        background: true,
        downloadId: 'bg-a',
      });
      const second = download({
        url: 'http://t/b',
        queue: true,
        downloadId: 'fg-b',
      });
      await flush();
      expect(getQueueStatus()).toMatchObject({ active: 1, pending: 1 });

      __emitNative('onDownloadComplete', {
        downloadId: 'bg-a',
        success: true,
        filePath: '/a',
      });
      await second;
      await flush();
      expect(getQueueStatus()).toMatchObject({ active: 0, pending: 0 });
      FileToolkit.download.mockReset();
    });

    it('releases background listeners when the download is cancelled', async () => {
      FileToolkit.download.mockImplementationOnce((opts: any) =>
        Promise.resolve({ success: true, downloadId: opts.downloadId })
      );
      FileToolkit.cancelDownload = jest
        .fn()
        .mockResolvedValue({ success: true });
      onDownloadComplete(() => {})(); // creates the emitter and its relay
      const base = __listenerCount('onDownloadComplete');
      await download({
        url: 'http://t/c',
        background: true,
        downloadId: 'bg-c',
        onProgress: () => {},
      });
      expect(__listenerCount('onDownloadComplete')).toBe(base + 1);

      await cancelDownload('bg-c');
      expect(__listenerCount('onDownloadComplete')).toBe(base);
      expect(__listenerCount('onDownloadError')).toBe(base);
      expect(__listenerCount('onDownloadProgress')).toBe(0);
    });

    it('a rejected duplicate id does not detach the running download', async () => {
      FileToolkit.download
        .mockImplementationOnce((opts: any) =>
          Promise.resolve({ success: true, downloadId: opts.downloadId })
        )
        .mockImplementationOnce((opts: any) =>
          Promise.resolve({
            success: false,
            downloadId: opts.downloadId,
            error: 'DOWNLOAD_ID_IN_USE',
          })
        );
      FileToolkit.cancelDownload = jest
        .fn()
        .mockResolvedValue({ success: true });
      onDownloadComplete(() => {})();
      const base = __listenerCount('onDownloadComplete');
      await download({
        url: 'http://t/d',
        background: true,
        downloadId: 'dup',
      });
      expect(
        await download({
          url: 'http://t/d',
          background: true,
          downloadId: 'dup',
        })
      ).toMatchObject({ success: false, error: 'DOWNLOAD_ID_IN_USE' });
      // The first download is still watched...
      expect(__listenerCount('onDownloadComplete')).toBe(base + 1);
      // ...and cancelling it still releases its listeners.
      await cancelDownload('dup');
      expect(__listenerCount('onDownloadComplete')).toBe(base);
    });

    it('keeps unheard background results for the next subscriber', async () => {
      FileToolkit.download.mockImplementationOnce((opts: any) =>
        Promise.resolve({ success: true, downloadId: opts.downloadId })
      );
      // Finished while the app was closed — nobody is subscribed yet.
      __emitNative('onDownloadComplete', { downloadId: 'old', success: true });
      // Belongs to a download started in this session: reported via its promise.
      await download({ url: 'http://t/w', background: true, downloadId: 'w' });
      __emitNative('onDownloadComplete', { downloadId: 'w', success: true });
      // A failed foreground download of this session is reported by its promise.
      await download({ url: 'http://t/f', downloadId: 'fg-f' });
      __emitNative('onDownloadError', {
        downloadId: 'fg-f',
        error: 'HTTP 500',
      });
      const errors: string[] = [];
      const offErr = onDownloadError((e) => errors.push(e.downloadId));

      const seen: string[] = [];
      const off = onDownloadComplete((e) => seen.push(e.downloadId));
      expect(seen).toEqual([]); // delivered after subscribe returns
      await flush();
      expect(seen).toEqual(['old']);
      expect(errors).toEqual([]);
      offErr();

      __emitNative('onDownloadComplete', { downloadId: 'live', success: true });
      expect(seen).toEqual(['old', 'live']);
      off();
    });

    it('only sends retry.delay when it is a number', async () => {
      FileToolkit.download.mockImplementation((opts: any) =>
        Promise.resolve({
          success: true,
          filePath: '/f',
          downloadId: opts.downloadId,
        })
      );
      await download({ url: 'http://t/r', retry: { attempts: 2 } });
      await download({ url: 'http://t/r', retry: { attempts: 2, delay: 0 } });
      expect(FileToolkit.download.mock.calls[0][0].retry).toEqual({
        attempts: 2,
      });
      expect(FileToolkit.download.mock.calls[1][0].retry).toEqual({
        attempts: 2,
        delay: 0,
      });
      FileToolkit.download.mockReset();
    });
  });

  describe('input normalisation', () => {
    it('parses data URIs with parameters, suffixes or no media type', async () => {
      FileToolkit.saveBase64AsFile = jest
        .fn()
        .mockResolvedValue({ success: true });
      await saveBase64AsFile({
        base64Data: 'data:text/plain;charset=utf-8;base64,SGk=',
      });
      await saveBase64AsFile({
        base64Data: 'data:image/svg+xml;base64,PHN2Zy8+',
      });
      await saveBase64AsFile({ base64Data: 'data:;base64,AAAA' });
      const calls = FileToolkit.saveBase64AsFile.mock.calls.map(
        (c: any) => c[0]
      );
      expect(calls.map((c: any) => c.base64Data)).toEqual([
        'SGk=',
        'PHN2Zy8+',
        'AAAA',
      ]);
      expect(calls[0].fileName).toMatch(/^file_\d+\.txt$/);
      expect(calls[1].fileName).toMatch(/^file_\d+\.svg$/);
      expect(calls[2].fileName).toMatch(/^file_\d+\.bin$/);

      const notBase64 = await saveBase64AsFile({
        base64Data: 'data:text/plain,hello',
      });
      expect(notBase64.success).toBe(false);
      expect(FileToolkit.saveBase64AsFile).toHaveBeenCalledTimes(3);
    });

    it('accepts file:// URIs wherever a path is expected', async () => {
      FileToolkit.readFile = jest
        .fn()
        .mockResolvedValue({ success: true, data: 'x' });
      await readFile('file:///data/My%20File.txt');
      await readFile('file://localhost/data/a.txt');
      await readFile('/data/100%.txt');
      expect(FileToolkit.readFile.mock.calls.map((c: any) => c[0])).toEqual([
        '/data/My File.txt',
        '/data/a.txt',
        '/data/100%.txt',
      ]);
    });
  });

  it('reports the legacy bridge as unavailable with an actionable error', async () => {
    let mod: any;
    jest.isolateModules(() => {
      // Legacy bridge on iOS: the module exists but most methods are missing.
      jest.doMock('../NativeFileToolkit', () => ({
        __esModule: true,
        default: { saveBase64AsFile: jest.fn() },
      }));
      mod = require('../index');
    });
    expect(mod.isAvailable).toBe(false);
    const res = await mod.download({ url: 'http://t/x' });
    expect(res.success).toBe(false);
    expect(res.error).toMatch(/New Architecture/);
  });
});
