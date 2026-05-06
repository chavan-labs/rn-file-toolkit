import { useState } from 'react';
import { View, Text, StyleSheet, TouchableOpacity, Alert } from 'react-native';
import { saveBase64AsFile } from '../../src';

export default function Base64Example() {
  const [filePath, setFilePath] = useState<string>('');
  const [loading, setLoading] = useState(false);

  // Sample base64 image (1x1 red pixel PNG)
  const sampleDataURI =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==';

  // Sample plain base64 text
  const sampleBase64Text = 'SGVsbG8gZnJvbSBybi1kb3dubG9hZGVyIQ=='; // "Hello from rn-file-toolkit!"

  const handleSaveDataURI = async () => {
    setLoading(true);
    try {
      const result = await saveBase64AsFile({
        base64Data: sampleDataURI,
        fileName: 'sample_image.png',
        destination: 'documents',
      });

      if (result.success && result.filePath) {
        setFilePath(result.filePath);
        Alert.alert('Success', `File saved at:\n${result.filePath}`);
      } else {
        Alert.alert('Error', result.error || 'Failed to save file');
      }
    } catch (error: any) {
      Alert.alert('Error', error.message);
    } finally {
      setLoading(false);
    }
  };

  const handleSaveBase64Text = async () => {
    setLoading(true);
    try {
      const result = await saveBase64AsFile({
        base64Data: sampleBase64Text,
        fileName: 'sample_text.txt',
        destination: 'cache',
      });

      if (result.success && result.filePath) {
        setFilePath(result.filePath);
        Alert.alert('Success', `Text file saved at:\n${result.filePath}`);
      } else {
        Alert.alert('Error', result.error || 'Failed to save file');
      }
    } catch (error: any) {
      Alert.alert('Error', error.message);
    } finally {
      setLoading(false);
    }
  };

  return (
    <View style={styles.container}>
      <Text style={styles.title}>Base64 & Data URI Examples</Text>

      <TouchableOpacity
        style={[styles.button, loading && styles.buttonDisabled]}
        onPress={handleSaveDataURI}
        disabled={loading}
      >
        <Text style={styles.buttonText}>
          {loading ? 'Saving...' : 'Save Data URI (Image)'}
        </Text>
      </TouchableOpacity>

      <TouchableOpacity
        style={[styles.button, loading && styles.buttonDisabled]}
        onPress={handleSaveBase64Text}
        disabled={loading}
      >
        <Text style={styles.buttonText}>
          {loading ? 'Saving...' : 'Save Base64 (Text)'}
        </Text>
      </TouchableOpacity>

      {filePath ? (
        <View style={styles.resultContainer}>
          <Text style={styles.resultLabel}>Last Saved:</Text>
          <Text style={styles.resultPath}>{filePath}</Text>
        </View>
      ) : null}

      <View style={styles.infoContainer}>
        <Text style={styles.infoText}>
          This example demonstrates:{'\n\n'}• Saving data URIs (with MIME type)
          {'\n'}• Saving plain base64 strings{'\n'}• Auto file extension
          detection{'\n'}• Different destinations (documents/cache)
        </Text>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    padding: 20,
    backgroundColor: '#f5f5f5',
  },
  title: {
    fontSize: 24,
    fontWeight: 'bold',
    marginBottom: 30,
    textAlign: 'center',
  },
  button: {
    backgroundColor: '#007AFF',
    padding: 16,
    borderRadius: 8,
    marginBottom: 12,
  },
  buttonDisabled: {
    backgroundColor: '#ccc',
  },
  buttonText: {
    color: 'white',
    fontSize: 16,
    fontWeight: '600',
    textAlign: 'center',
  },
  resultContainer: {
    marginTop: 20,
    padding: 16,
    backgroundColor: '#e8f5e9',
    borderRadius: 8,
  },
  resultLabel: {
    fontSize: 14,
    fontWeight: '600',
    marginBottom: 8,
    color: '#2e7d32',
  },
  resultPath: {
    fontSize: 12,
    color: '#1b5e20',
  },
  infoContainer: {
    marginTop: 30,
    padding: 16,
    backgroundColor: '#fff3e0',
    borderRadius: 8,
  },
  infoText: {
    fontSize: 14,
    color: '#e65100',
    lineHeight: 20,
  },
});
