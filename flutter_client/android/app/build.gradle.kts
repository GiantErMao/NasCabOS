import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 同一套代码，两种构建变体：
//  - regular：普通手机版 → portrait（竖屏）。
//  - hd     ：大屏版，用于 Pico VR 一体机 / Pad 等高分设备 → landscape（横屏），
//             使 Pico 分配 1600x900 大屏。运行时排版由 DeviceUtils.isLargeScreenAndroid 决定。
//
// 屏幕方向由 flavor 专属源集 Manifest 覆盖注入（AGP 标准能力，实测有效）：
//   src/hd/AndroidManifest.xml      -> android:screenOrientation="landscape"
//   src/regular/AndroidManifest.xml -> android:screenOrientation="portrait"
// 主 Manifest（src/main）不声明该属性。
// 构建：BUILD_NUMBER=<code> ./build_flavor.sh hd|regular；签名：./sign_flavor.sh hd|regular。
// 验证时务必用正确的枚举表：0=landscape、1=portrait（枚举从 -1=unspecified 开始）。

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
val releaseStoreFile = keystoreProperties["storeFile"]?.let {
    rootProject.file(it.toString())
}
val hasReleaseSigning = releaseStoreFile?.isFile == true &&
    keystoreProperties["keyAlias"] != null &&
    keystoreProperties["keyPassword"] != null &&
    keystoreProperties["storePassword"] != null
android {
    namespace = "com.nascabos.mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    flavorDimensions += "mode"
    productFlavors {
        create("regular") {
            dimension = "mode"
        }
        create("hd") {
            dimension = "mode"
        }
    }

    defaultConfig {
        applicationId = "com.nascabos.mobile"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    if (hasReleaseSigning) {
        signingConfigs {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String?
                keyPassword = keystoreProperties["keyPassword"] as String?
                storeFile = releaseStoreFile
                storePassword = keystoreProperties["storePassword"] as String?
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.media3:media3-exoplayer:1.10.0")
    implementation("androidx.media3:media3-exoplayer-hls:1.10.0")
    implementation("androidx.media3:media3-ui:1.10.0")
    // 万能软解：将 tv_android/app/libs/lib-decoder-ffmpeg-release.aar 复制到本模块 libs/ 后取消注释
    implementation(files("libs/lib-decoder-ffmpeg-release.aar"))
}
