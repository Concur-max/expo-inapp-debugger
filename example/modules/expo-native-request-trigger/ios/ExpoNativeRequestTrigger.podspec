require 'json'

package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

Pod::Spec.new do |s|
  s.name = 'ExpoNativeRequestTrigger'
  s.version = package['version']
  s.summary = 'Local Expo module used by the example app to fire native HTTP requests.'
  s.description = 'A minimal example-only Expo module that issues native GET and POST requests so expo-inapp-debugger can verify native network capture.'
  s.license = 'MIT'
  s.author = 'OpenAI'
  s.homepage = 'https://example.invalid/expo-native-request-trigger'
  s.platform = :ios, '15.1'
  s.swift_version = '5.9'
  s.source = { git: 'https://example.invalid/expo-native-request-trigger.git', tag: s.version.to_s }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_COMPILATION_MODE' => 'wholemodule'
  }

  s.source_files = '**/*.{h,m,swift}'
end
