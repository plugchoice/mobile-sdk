import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// This module is built in two places: in this repository's Gradle build (android/), and inside
// React Native host apps, where Expo autolinking includes it as a project of the app's own build.
// The host build has no `libs` version catalog and brings its own Android Gradle and Kotlin
// plugins, so this file names plugins without versions and spells dependencies out in full.
plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

// `com.plugchoice:plugchoice`. Publishing (Maven Central, the local Maven repository) is set up by
// this repository's root build, android/build.gradle.kts; a composite build (`includeBuild`)
// substitutes this project for the coordinates.
group = "com.plugchoice"
version = "0.5.0" // x-release-please-version

android {
    namespace = "com.plugchoice"
    compileSdk = 36

    defaultConfig {
        // WifiNetworkSpecifier needs API 29.
        minSdk = 29
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    lint {
        // Dependencies are spelled out on purpose (see the top of this file).
        disable += "UseTomlInstead"
    }
}

kotlin {
    explicitApi()
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    // The Link screen is started through an ActivityResultContract: part of the public API.
    api("androidx.activity:activity-ktx:1.12.4")
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.webkit:webkit:1.15.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    // camera.scanCode: the Google code scanner (Play services UI, no camera permission).
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")

    testImplementation("junit:junit:4.13.2")
    // Virtual time for the client secret's 30 s timeout.
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
    // The real org.json: android.jar only has stubs on the JVM.
    testImplementation("org.json:json:20260814")
}
