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
    AndroidConfig.Permissions.addPermission(
      modConfig.modResults,
      'android.permission.INTERNET'
    );
    AndroidConfig.Permissions.addPermission(
      modConfig.modResults,
      'android.permission.WRITE_EXTERNAL_STORAGE'
    );
    AndroidConfig.Permissions.addPermission(
      modConfig.modResults,
      'android.permission.READ_EXTERNAL_STORAGE'
    );
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
    return modConfig;
  });

  return config;
};

module.exports = createRunOncePlugin(
  withFileToolkitPermissions,
  pkg.name,
  pkg.version
);
