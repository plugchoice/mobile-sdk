// The Expo module behind `@plugchoice/react-native` on Android. Only built inside a React Native
// host app: Expo autolinking includes it (as :plugchoice-react-native) together with the Android
// SDK in plugchoice/ (as :plugchoice-sdk), a copy of the repository's android/plugchoice made when
// the package is packed (scripts/copy-native-sdk.js). See expo-module.config.json.
plugins {
    id("com.android.library")
    id("expo-module-gradle-plugin")
}

group = "com.plugchoice"
version = "0.3.0" // x-release-please-version

android {
    namespace = "com.plugchoice.reactnative"

    defaultConfig {
        // The SDK's minimum (WifiNetworkSpecifier).
        minSdk = 29
    }
}

expoModule {
    // Always built from source inside the host app, never published as a prebuilt module.
    canBePublished = false
}

dependencies {
    implementation(project(":plugchoice-sdk"))
}
