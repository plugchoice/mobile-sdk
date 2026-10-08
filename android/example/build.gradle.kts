import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
}

android {
    namespace = "com.plugchoice.example"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.plugchoice.example"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "0.5.0" // x-release-please-version
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(project(":plugchoice"))
    implementation(libs.androidx.activity.ktx)
    implementation(libs.androidx.core.ktx)
}
