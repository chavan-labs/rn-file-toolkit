import { useState } from 'react';
import {
  StyleSheet,
  View,
  Text,
  TouchableOpacity,
  ActivityIndicator,
  Alert,
  ScrollView,
} from 'react-native';
import {
  download,
  shareFile,
  openFile,
  type ProgressInfo,
} from 'rn-file-toolkit';

export default function App() {
  const [progress, setProgress] = useState<number>(0);
  const [downloading, setDownloading] = useState(false);
  const [result, setResult] = useState<string>('');
  const [downloadedFilePath, setDownloadedFilePath] = useState<string>('');

  // ─── Retry demo state ──────────────────────────────────────────────────────
  const [retryDownloading, setRetryDownloading] = useState(false);
  const [retryProgress, setRetryProgress] = useState(0);
  const [retryLog, setRetryLog] = useState<string[]>([]);

  const startDownload = async () => {
    setDownloading(true);
    setProgress(0);
    setResult('');
    setDownloadedFilePath('');

    const SAMPLE_URL =
      'https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf';

    const res = await download({
      url: SAMPLE_URL,
      onProgress: (info: ProgressInfo) => setProgress(info.percent),
    });

    setDownloading(false);

    if (res.success) {
      setResult(`✅ Saved at:\n${res.filePath}`);
      setDownloadedFilePath(res.filePath || '');
    } else {
      setResult(`❌ Error: ${res.error}`);
    }
  };

  // ─── Retry demo ────────────────────────────────────────────────────────────
  // Uses a bad URL first to intentionally trigger retries, then a working URL.
  // In a real app you'd just use the real URL — retries fire only on network errors.
  const startRetryDownload = async () => {
    setRetryDownloading(true);
    setRetryProgress(0);
    setRetryLog(['🚀 Starting download with auto-retry (3 attempts)...']);

    // Intentionally broken URL so first attempt fails → triggers retries
    const BAD_URL = 'https://httpstat.us/500';

    const res = await download({
      url: BAD_URL,
      destination: 'cache',
      retry: {
        attempts: 3,
        delay: 1500, // 1.5s → 3s → 6s
        onRetry: (attempt, error) => {
          setRetryLog((prev) => [
            ...prev,
            `🔄 Retry #${attempt} after error: ${error}`,
          ]);
        },
      },
      onProgress: (info: ProgressInfo) => setRetryProgress(info.percent),
    });

    setRetryDownloading(false);

    if (res.success) {
      setRetryLog((prev) => [...prev, `✅ Success! File: ${res.filePath}`]);
    } else {
      setRetryLog((prev) => [
        ...prev,
        `❌ Failed after all retries: ${res.error}`,
      ]);
    }
  };

  const handleShareFile = async () => {
    if (!downloadedFilePath) {
      Alert.alert('No File', 'Please download a file first');
      return;
    }
    const res = await shareFile({
      filePath: downloadedFilePath,
      title: 'Share PDF Document',
      subject: 'Check out this PDF',
    });
    if (!res.success) Alert.alert('Error', res.error || 'Failed to share');
  };

  const handleOpenFile = async () => {
    if (!downloadedFilePath) {
      Alert.alert('No File', 'Please download a file first');
      return;
    }
    const res = await openFile({
      filePath: downloadedFilePath,
      mimeType: 'application/pdf',
    });
    if (!res.success) Alert.alert('Error', res.error || 'Failed to open');
  };

  return (
    <View style={styles.container}>
      <ScrollView
        contentContainerStyle={styles.scroll}
        showsVerticalScrollIndicator={false}
      >
        {/* ── Normal download ── */}
        <View style={styles.card}>
          <Text style={styles.title}>🚀 rn-file-toolkit</Text>
          <Text style={styles.subtitle}>Pure native downloads, zero deps.</Text>

          <View style={styles.progressContainer}>
            <Text style={styles.progressText}>{progress}%</Text>
            <View style={styles.progressBarBg}>
              <View
                style={[styles.progressBarFill, { width: `${progress}%` }]}
              />
            </View>
          </View>

          <TouchableOpacity
            style={[styles.button, downloading && styles.buttonDisabled]}
            onPress={startDownload}
            disabled={downloading}
          >
            {downloading ? (
              <ActivityIndicator color="#FFF" />
            ) : (
              <Text style={styles.buttonText}>⬇️ Download Sample PDF</Text>
            )}
          </TouchableOpacity>

          {downloadedFilePath ? (
            <View style={styles.actionButtons}>
              <TouchableOpacity
                style={[styles.button, styles.shareButton]}
                onPress={handleShareFile}
              >
                <Text style={styles.buttonText}>📤 Share</Text>
              </TouchableOpacity>
              <TouchableOpacity
                style={[styles.button, styles.openButton]}
                onPress={handleOpenFile}
              >
                <Text style={styles.buttonText}>📂 Open</Text>
              </TouchableOpacity>
            </View>
          ) : null}

          {result !== '' && <Text style={styles.resultText}>{result}</Text>}
        </View>

        {/* ── Auto-retry demo ── */}
        <View style={styles.card}>
          <Text style={styles.sectionTitle}>🔄 Auto-Retry Demo</Text>
          <Text style={styles.subtitle}>
            Retries automatically on network errors with exponential backoff
            (1.5s → 3s → 6s).
          </Text>

          {retryDownloading && (
            <View style={styles.progressContainer}>
              <Text style={styles.progressText}>{retryProgress}%</Text>
              <View style={styles.progressBarBg}>
                <View
                  style={[
                    styles.progressBarFill,
                    styles.retryProgressFill,
                    { width: `${retryProgress}%` },
                  ]}
                />
              </View>
            </View>
          )}

          <TouchableOpacity
            style={[
              styles.button,
              styles.retryButton,
              retryDownloading && styles.buttonDisabled,
            ]}
            onPress={startRetryDownload}
            disabled={retryDownloading}
          >
            {retryDownloading ? (
              <ActivityIndicator color="#FFF" />
            ) : (
              <Text style={styles.buttonText}>▶ Run Retry Demo</Text>
            )}
          </TouchableOpacity>

          {retryLog.length > 0 && (
            <View style={styles.logBox}>
              {retryLog.map((line, i) => (
                <Text key={i} style={styles.logLine}>
                  {line}
                </Text>
              ))}
            </View>
          )}
        </View>
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#0F172A',
  },
  scroll: {
    padding: 20,
    paddingTop: 8,
    gap: 16,
  },
  card: {
    backgroundColor: '#1E293B',
    padding: 24,
    borderRadius: 20,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 10 },
    shadowOpacity: 0.3,
    shadowRadius: 20,
    elevation: 10,
  },
  title: {
    fontSize: 22,
    fontWeight: '800',
    color: '#F8FAFC',
    marginBottom: 8,
    textAlign: 'center',
  },
  sectionTitle: {
    fontSize: 18,
    fontWeight: '700',
    color: '#F8FAFC',
    marginBottom: 8,
  },
  subtitle: {
    fontSize: 13,
    color: '#94A3B8',
    marginBottom: 24,
    textAlign: 'center',
  },
  progressContainer: {
    alignItems: 'center',
    marginBottom: 24,
  },
  progressText: {
    fontSize: 48,
    fontWeight: '900',
    color: '#38BDF8',
    marginBottom: 12,
  },
  progressBarBg: {
    width: '100%',
    height: 12,
    backgroundColor: '#334155',
    borderRadius: 6,
    overflow: 'hidden',
  },
  progressBarFill: {
    height: '100%',
    backgroundColor: '#38BDF8',
  },
  retryProgressFill: {
    backgroundColor: '#A78BFA',
  },
  button: {
    backgroundColor: '#38BDF8',
    paddingVertical: 16,
    borderRadius: 12,
    alignItems: 'center',
  },
  buttonDisabled: {
    opacity: 0.6,
  },
  buttonText: {
    color: '#0F172A',
    fontSize: 16,
    fontWeight: '700',
  },
  resultText: {
    marginTop: 20,
    color: '#10B981',
    textAlign: 'center',
    fontSize: 12,
    fontWeight: '500',
    lineHeight: 18,
  },
  actionButtons: {
    flexDirection: 'row',
    gap: 12,
    marginTop: 16,
  },
  shareButton: {
    backgroundColor: '#8B5CF6',
    flex: 1,
  },
  openButton: {
    backgroundColor: '#F59E0B',
    flex: 1,
  },
  retryButton: {
    backgroundColor: '#A78BFA',
  },
  logBox: {
    marginTop: 16,
    backgroundColor: '#0F172A',
    borderRadius: 10,
    padding: 12,
    gap: 6,
  },
  logLine: {
    color: '#CBD5E1',
    fontSize: 12,
    fontFamily: 'monospace',
  },
});
