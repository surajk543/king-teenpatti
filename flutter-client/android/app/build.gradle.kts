import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The upload key, read from android/key.properties — which is git-ignored,
// along with the keystore itself. Losing either means never being able to
// publish an update to an existing Play listing again, so both belong in a
// durable private backup and nowhere near the repository.
//
// When the file is absent the release build falls back to debug signing. That
// keeps `flutter run --release` working for anyone who has cloned this without
// the key, and it is safe because Play refuses a debug-signed upload outright
// — the mistake cannot reach a store listing, it just fails at upload.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasUploadKey = keystorePropertiesFile.exists()
if (hasUploadKey) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// A RELEASE build split per ABI is refused (24 Sep 2026, owner's "fix all
// bugs"; release review RC-05). `flutter build apk --split-per-abi` gives each
// APK the pubspec build number PLUS an ABI offset (1007, 2007, 4007 for build
// 7): a phone that sideloads one reports that as its build, so no
// MIN_CLIENT_BUILD floor ever holds it back, and it cannot take a Play update
// either (Play's 8 is "older" than 2007). The store upload is the App Bundle
// (`flutter build appbundle --release`), which Play splits itself with the
// true version code. For a throwaway test build that really wants the split
// APKs: `--android-project-arg=allowSplitPerAbiRelease=true`.
val splitPerAbi = findProperty("split-per-abi")?.toString()?.toBoolean() ?: false
if (splitPerAbi &&
    findProperty("allowSplitPerAbiRelease") == null &&
    gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) }
) {
    throw GradleException(
        "Refusing a release build split per ABI: its APKs carry versionCodes " +
            "1000+/2000+/4000+ that no MIN_CLIENT_BUILD floor catches and Play " +
            "can never update. Ship the App Bundle (flutter build appbundle " +
            "--release) or one universal APK (flutter build apk --release). " +
            "A test build may pass --android-project-arg=allowSplitPerAbiRelease=true.",
    )
}

android {
    namespace = "com.sungamestudio.kingteenpatti"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.sungamestudio.kingteenpatti"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasUploadKey) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = keystoreProperties["storeFile"]?.let { rootProject.file(it) }
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasUploadKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // Shrink and obfuscate. Flutter's own rules are added by the
            // plugin; ours only keep what reflection reaches.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
