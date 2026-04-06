const path = require('path');
const fs = require('fs');
const { getDefaultConfig } = require('expo/metro-config');

const projectRoot = __dirname;
const packageRoot = path.resolve(projectRoot, '..');
const appNodeModules = path.resolve(projectRoot, 'node_modules');
const appPnpmNodeModules = path.resolve(appNodeModules, '.pnpm/node_modules');

function resolveFromApp(packageName) {
  const candidates = [
    path.resolve(appNodeModules, packageName),
    path.resolve(appPnpmNodeModules, packageName),
  ];

  for (const candidate of candidates) {
    if (fs.existsSync(path.join(candidate, 'package.json'))) {
      return fs.realpathSync(candidate);
    }
  }

  return path.dirname(require.resolve(`${packageName}/package.json`));
}

const config = getDefaultConfig(projectRoot);

config.watchFolders = Array.from(
  new Set([...(config.watchFolders || []), packageRoot])
);

config.resolver.disableHierarchicalLookup = true;
config.resolver.nodeModulesPaths = Array.from(
  new Set([
    ...(config.resolver.nodeModulesPaths || []),
    appNodeModules,
    appPnpmNodeModules,
  ])
);
config.resolver.extraNodeModules = {
  ...(config.resolver.extraNodeModules || {}),
  'expo-inapp-debugger': packageRoot,
  expo: resolveFromApp('expo'),
  'expo-modules-core': resolveFromApp('expo-modules-core'),
  react: resolveFromApp('react'),
  'react-native': resolveFromApp('react-native'),
};

module.exports = config;
