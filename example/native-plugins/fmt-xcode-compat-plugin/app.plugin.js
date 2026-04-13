const { withDangerousMod } = require('expo/config-plugins');
const fs = require('fs');
const path = require('path');

module.exports = function withFmtXcodeCompatPlugin(config) {
  const marker = '# expo-inapp-debugger fmt xcode compat';

  return withDangerousMod(config, ['ios', async (cfg) => {
    const podfilePath = path.join(cfg.modRequest.platformProjectRoot, 'Podfile');
    if (!fs.existsSync(podfilePath)) {
      console.warn('[fmt-xcode-compat-plugin] Podfile not found, skipping');
      return cfg;
    }

    let content = fs.readFileSync(podfilePath, 'utf8');
    if (content.includes(marker)) {
      console.log('[fmt-xcode-compat-plugin] fmt compatibility already configured ✓');
      return cfg;
    }

    const reactNativePostInstallRegex = /(react_native_post_install\([\s\S]*?\n\s*\)\n)/;
    if (!reactNativePostInstallRegex.test(content)) {
      console.warn('[fmt-xcode-compat-plugin] Could not find react_native_post_install block');
      return cfg;
    }

    const rubySnippet = `    ${marker}
    installer.pods_project.targets.each do |target|
      next unless target.name == 'fmt'

      target.build_configurations.each do |build_configuration|
        build_configuration.build_settings['CLANG_CXX_LANGUAGE_STANDARD'] = 'c++17'
      end
    end

    fmt_support_files_dir = File.join(installer.sandbox.root.to_s, 'Target Support Files', 'fmt')
    Dir.glob(File.join(fmt_support_files_dir, 'fmt.*.xcconfig')).each do |xcconfig_path|
      xcconfig_contents = File.read(xcconfig_path)
      updated_contents = xcconfig_contents.gsub(
        /^CLANG_CXX_LANGUAGE_STANDARD = .+$/,
        'CLANG_CXX_LANGUAGE_STANDARD = c++17'
      )

      if updated_contents == xcconfig_contents
        updated_contents = "#{xcconfig_contents.rstrip}\nCLANG_CXX_LANGUAGE_STANDARD = c++17\n"
      end

      File.write(xcconfig_path, updated_contents)
    end

    installer.pods_project.save
`;

    content = content.replace(
      reactNativePostInstallRegex,
      `$1${rubySnippet}`
    );

    fs.writeFileSync(podfilePath, content, 'utf8');
    console.log('[fmt-xcode-compat-plugin] Injected fmt/Xcode compatibility fix ✓');
    return cfg;
  }]);
};
