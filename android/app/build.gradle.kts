plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.aimemo.aimemo"
    compileSdk = 36  // flutter_gemma requires SDK 36
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.aimemo.aimemo"
        minSdk = 26  // LiteRT-LM requires API 26+
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    // LiteRT-LM on-device inference engine
    // https://developers.google.com/edge/litert-lm/android
    implementation("com.google.ai.edge.litertlm:litertlm-android:latest.release")

    // LiteRT GPU acceleration delegate (Crucial for Gemma 4 on 8GB RAM devices)
    implementation("com.google.ai.edge.litert:litert-gpu:1.4.2")
    implementation("com.google.ai.edge.litert:litert-gpu-api:1.4.2")

    // Kotlin coroutines (for LiteRT-LM async API bridge)
    // Version aligned with Kotlin 2.1.x
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
}

flutter {
    source = "../.."
}
