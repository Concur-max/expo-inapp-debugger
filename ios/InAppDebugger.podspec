require 'json'

package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

new_arch_enabled = ENV['RCT_NEW_ARCH_ENABLED'] == '1'
new_arch_compiler_flags = '-DRCT_NEW_ARCH_ENABLED'

Pod::Spec.new do |s|
  s.name = 'InAppDebugger'
  s.version = package['version']
  s.summary = 'Native in-app debugger for Expo and React Native'
  s.description = 'Provides a native floating debugger entry and panel for Expo prebuild and bare React Native apps.'
  s.license = package['license'] || 'MIT'
  s.author = package['author'] || 'xingyuyang'
  s.homepage = package['homepage'] || 'https://localhost/expo-inapp-debugger'
  s.platform = :ios, '15.5'
  s.swift_version = '5.9'
  s.source = { git: 'https://localhost/expo-inapp-debugger' }
  s.static_framework = true

  s.compiler_flags = new_arch_compiler_flags if new_arch_enabled
  s.dependency 'ExpoModulesCore'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_COMPILATION_MODE' => 'wholemodule',
    'OTHER_SWIFT_FLAGS' => "$(inherited) #{new_arch_enabled ? new_arch_compiler_flags : ''}"
  }

  s.source_files = '**/*.{h,m,swift}'
end
