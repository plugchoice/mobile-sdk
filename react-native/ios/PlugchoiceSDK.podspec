require 'json'

package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

# The iOS SDK as a CocoaPod, for React Native and Expo apps: Expo autolinking
# adds it from node_modules next to PlugchoiceReactNative. Its sources are a
# copy of the repository's ios/Sources/PlugchoiceSDK, made when the package is
# packed (scripts/copy-native-sdk.js). Native iOS apps use Swift Package
# Manager instead (Package.swift at the repository root), with the same
# module name, PlugchoiceSDK.
#
# The pod and its module are PlugchoiceSDK, not Plugchoice: an app whose own
# target (and so Swift module) is named Plugchoice would otherwise fail to
# build ("circular dependency between modules 'Plugchoice' and
# 'PlugchoiceReactNative'"), because the app imports PlugchoiceReactNative,
# which imports the SDK.
Pod::Spec.new do |s|
  s.name            = 'PlugchoiceSDK'
  s.version         = package['version']
  s.summary         = 'The Plugchoice SDK: connect EV chargers to Plugchoice from an iOS app.'
  s.homepage        = package['homepage']
  s.license         = package['license']
  s.author          = 'Plugchoice'
  s.platforms       = { :ios => '16.0' }
  s.swift_version   = '5.9'
  s.source          = { :git => 'https://github.com/plugchoice/mobile-sdk.git', :tag => "v#{s.version}" }
  s.source_files    = 'PlugchoiceSDK/**/*.swift'
  s.frameworks      = 'AVFoundation', 'CoreBluetooth', 'CoreLocation', 'Network', 'NetworkExtension', 'Security', 'WebKit'
  # iOS 18+ only; weak, so apps still launch on iOS 16 and 17.
  s.weak_frameworks = 'AccessorySetupKit'
end
