import { download, setQueueOptions, getQueueStatus, session } from '../index';
import type { DownloadOptions } from '../index';
import { NativeModules } from 'react-native';

// Mock the native module
jest.mock('react-native', () => {
  let callbacks: Record<string, Function[]> = {};

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

  return {
    NativeModules: {
      FileToolkit: mockFileToolkit,
    },
    TurboModuleRegistry: {
      getEnforcing: jest.fn().mockReturnValue(mockFileToolkit),
    },
    NativeEventEmitter: jest.fn().mockImplementation(() => ({
      addListener: jest.fn((event, cb) => {
        if (!callbacks[event]) callbacks[event] = [];
        callbacks[event].push(cb);
        return { remove: jest.fn() };
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
});
