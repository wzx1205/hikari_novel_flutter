import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "pers.cyh128.hikari_novel"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    // 从 key.properties 读取签名信息（CI 通过 Secrets 注入，本地用 debug 签名回退）
    // 仅当 keystore 文件实际存在且非空时才使用 release 签名，避免 secret 缺失时构建崩溃
    val keyPropertiesFile = rootProject.file("android/key.properties")
    val keyProperties = Properties()
    if (keyPropertiesFile.exists()) {
        keyProperties.load(FileInputStream(keyPropertiesFile))
    }
    val keystoreFile = keyProperties["storeFile"]?.toString()?.let { file(it) }
    val hasValidKeystore = keystoreFile != null && keystoreFile.exists() && keystoreFile.length() > 0

    signingConfigs {
        create("release") {
            if (keyProperties.isNotEmpty() && hasValidKeystore) {
                keyAlias = keyProperties["keyAlias"] as String
                keyPassword = keyProperties["keyPassword"] as String
                storeFile = keystoreFile!!
                storePassword = keyProperties["storePassword"] as String
            }
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "pers.cyh128.hikari_novel"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // 有关键签名信息且 keystore 有效时用固定签名，否则回退 debug
            signingConfig = if (hasValidKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
