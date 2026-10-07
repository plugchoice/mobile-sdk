require 'json'

package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

# The Expo module behind `@plugchoice/react-native`: a thin wrapper around the
# Plugchoice SDK (the PlugchoiceSDK pod).
Pod::Spec.new do |s|
  s.name            = 'PlugchoiceReactNative'
  s.version         = package['version']
  s.summary         = package['description']
  s.homepage        = package['homepage']
  s.license         = package['license']
  s.author          = 'Plugchoice'
  # ExpoModulesCore's minimum.
  s.platforms       = { :ios => '16.4' }
  s.swift_version   = '5.9'
  s.source          = { :git => 'https://github.com/plugchoice/mobile-sdk.git', :tag => "v#{s.version}" }
  s.static_framework = true
  s.source_files    = 'PlugchoiceModule.swift'

  s.dependency 'ExpoModulesCore'
  s.dependency 'PlugchoiceSDK', package['version']

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }
end
