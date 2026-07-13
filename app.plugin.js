const {
  withInfoPlist,
  withAndroidManifest,
  AndroidConfig,
  createRunOncePlugin,
} = require('@expo/config-plugins');

const pkg = require('./package.json');

/**
 * Config plugin to add necessary permissions and background modes for rn-file-toolkit.
 */
const withFileToolkitPermissions = (config) => {
  // 1. Android: Add internet and storage permissions
  config = withAndroidManifest(config, (modConfig) => {
    const manifest = modConfig.modResults.manifest;

    // Ensure uses-permission array exists
    if (!manifest['uses-permission']) {
      manifest['uses-permission'] = [];
    }

    // INTERNET — no maxSdkVersion needed
    AndroidConfig.Permissions.addPermission(
      modConfig.modResults,
      'android.permission.INTERNET'
    );

    // Storage permissions — only needed on API ≤ 32 (deprecated on Android 13+)
    const addPermissionWithMaxSdk = (name, maxSdk) => {
      const exists = manifest['uses-permission'].some(
        (p) => p.$?.['android:name'] === name
      );
      if (!exists) {
        manifest['uses-permission'].push({
          $: {
            'android:name': name,
            'android:maxSdkVersion': String(maxSdk),
          },
        });
      }
    };

    addPermissionWithMaxSdk('android.permission.WRITE_EXTERNAL_STORAGE', 32);
    addPermissionWithMaxSdk('android.permission.READ_EXTERNAL_STORAGE', 32);

    return modConfig;
  });

  // 2. iOS: Add 'fetch' background mode
  config = withInfoPlist(config, (modConfig) => {
    if (!Array.isArray(modConfig.modResults.UIBackgroundModes)) {
      modConfig.modResults.UIBackgroundModes = [];
    }
    if (!modConfig.modResults.UIBackgroundModes.includes('fetch')) {
      modConfig.modResults.UIBackgroundModes.push('fetch');
    }

    // Photo Library write permission for saveToMediaStore
    if (!modConfig.modResults.NSPhotoLibraryAddUsageDescription) {
      modConfig.modResults.NSPhotoLibraryAddUsageDescription =
        'Allow $(PRODUCT_NAME) to save downloaded media to your Photo Library';
    }

    return modConfig;
  });

  return config;
};

module.exports = createRunOncePlugin(
  withFileToolkitPermissions,
  pkg.name,
  pkg.version
);
