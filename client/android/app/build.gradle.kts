import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "dev.nancunchild.elecon"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.nancunchild.elecon"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // 签名策略区分「发布」与「门禁」：
            //  - 发布路径（release.yml 置 ELECON_REQUIRE_RELEASE_SIGNING=true）：必须有 key.properties，
            //    否则 fail——绝不发布 debug 签名的 APK。
            //  - CI 门禁（ci.yml 的 client-release 只验证 release 能编出且含 INTERNET）与本地 release：
            //    无 key.properties 时回退 debug 签名——门禁不产出可发布物，无需生产密钥。
            //    （此前用 System.getenv("CI") 一刀切，把门禁误当发布 → 门禁无密钥即 fail。）
            if (System.getenv("ELECON_REQUIRE_RELEASE_SIGNING") == "true" && !keystorePropertiesFile.exists()) {
                throw GradleException("发布构建要求 android/key.properties（ELECON_REQUIRE_RELEASE_SIGNING=true）")
            }
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
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
