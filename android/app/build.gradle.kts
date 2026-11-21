import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: values come from android/key.properties (git-ignored) or, in CI,
// from environment variables. Nothing secret is committed. See README "Release build".
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}
fun signingValue(key: String, env: String): String? =
    (keystoreProperties.getProperty(key) ?: System.getenv(env))?.takeIf { it.isNotBlank() }

android {
    namespace = "com.stridemate.app"
    compileSdk = 35
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.stridemate.app"
        // Health Connect client requires API 26+.
        minSdk = 26
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // AdMob app ID: Google's TEST app ID unless ADMOB_APP_ID_ANDROID is set
        // (gradle property or environment variable) for a release build.
        manifestPlaceholders["admobAppId"] =
            (project.findProperty("ADMOB_APP_ID_ANDROID") as String?)
                ?: System.getenv("ADMOB_APP_ID_ANDROID")?.takeIf { it.isNotBlank() }
                ?: "ca-app-pub-3940256099942544~3347511713"
    }

    signingConfigs {
        // Shared TEST key (committed on purpose, public password "android") so every
        // CI build has the same signature and can be installed over the previous one.
        // Never use it for Play uploads; release builds use key.properties below.
        getByName("debug") {
            storeFile = file("debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
        create("release") {
            val storePath = signingValue("storeFile", "STRIDEMATE_KEYSTORE_PATH")
            if (storePath != null) {
                storeFile = file(storePath)
                storePassword = signingValue("storePassword", "STRIDEMATE_KEYSTORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "STRIDEMATE_KEY_ALIAS")
                keyPassword = signingValue("keyPassword", "STRIDEMATE_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            val release = signingConfigs.getByName("release")
            // Without a release key the build is debug-signed so it still installs for
            // testing; Play will reject it. Supply key.properties for store uploads.
            signingConfig = if (release.storeFile != null) release else signingConfigs.getByName("debug")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.work:work-runtime-ktx:2.9.1")
    testImplementation("junit:junit:4.13.2")
}
