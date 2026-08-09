import java.util.Base64
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

// ─── ADR-024 信任 profile：从 dart-define 读，单一事实源 ─────────────────────────
//
// Flutter 把 `--dart-define=K=V` 以 base64(K=V) 的逗号分隔串传给 gradle 的
// `dart-defines` property。这里解出 ELECON_TRUST_PROFILE，据此决定 applicationId
// 后缀（护栏 3）与产物元数据标记（护栏 4b）。
//
// **为什么从 dart-define 读而不是另开一个 gradle property**：ADR-024 §2.3 护栏 3 要求
// 「DEV ⟺ applicationId 后缀 ⟺ ELECON_TRUST_PROFILE=dev-sideload 三者一致」。若让
// gradle 用独立开关，三者就可能各说各话——最坏情况是 Dart 侧编入了侧载入口、
// applicationId 却仍是正牌 app，正好造出 ADR 要防的那种可误发产物。从同一个
// dart-define 派生，三者一致是**结构性的**，不靠人记得两处都改。
//
// fail-closed（护栏 1）与 Dart 侧同构：解析不到 / 值不匹配 ⟹ 一律 DEPLOY。
val devSideloadProfileValue = "dev-sideload"

fun decodeDartDefines(): Map<String, String> {
    val raw = (project.findProperty("dart-defines") as String?) ?: return emptyMap()
    return raw.split(",")
        .filter { it.isNotBlank() }
        .mapNotNull { encoded ->
            val decoded = try {
                String(Base64.getDecoder().decode(encoded), Charsets.UTF_8)
            } catch (_: IllegalArgumentException) {
                return@mapNotNull null // 无法解码的条目直接忽略（fail-closed：不认即非 DEV）
            }
            val eq = decoded.indexOf('=')
            if (eq <= 0) null else decoded.substring(0, eq) to decoded.substring(eq + 1)
        }
        .toMap()
}

val trustProfile = decodeDartDefines()["ELECON_TRUST_PROFILE"] ?: ""
val sideloadEnabled = trustProfile == devSideloadProfileValue
val buildProfileLabel = if (sideloadEnabled) "DEV-SIDELOAD" else "DEPLOY"

// 护栏 4b 的产物级证据：把 profile 标记写成 APK 内的资产文件。
// 选资产文件而非 manifest meta-data / resValue，是为了让 gate 脚本能只用 unzip
// 就机械读出（无需 Android SDK 工具链），CI 与本地行为一致。
val buildProfileAssetsDir = layout.buildDirectory.dir("generated/elecon-profile-assets")
val writeBuildProfileMarker = tasks.register("writeEleconBuildProfileMarker") {
    val outDir = buildProfileAssetsDir
    val label = buildProfileLabel
    val profile = trustProfile
    // 🔒 **inputs 必须声明**：profile 只存在于构建脚本的值里，不是任何输入文件。少了这两行，
    // gradle 只看输出目录就判 UP-TO-DATE，于是 DEV 构建会原样留下上一次 DEPLOY 构建写的
    // 标记——护栏 4b 就会把 DEV 产物认成 DEPLOY 放行。（实测踩到过：2026-08-07 首次
    // DEV 构建的标记为陈旧的 DEPLOY，靠护栏 4a 的符号 grep 才拦住。这正是 ADR-024 §5.3
    // 要求「二者并用」的实证——单靠元数据标记会被自身的构建缓存击穿。）
    inputs.property("eleconBuildProfileLabel", label)
    inputs.property("eleconTrustProfile", profile)
    outputs.dir(outDir)
    doLast {
        val dir = outDir.get().asFile
        dir.mkdirs()
        // 首行是 gate 断言的对象；第二行仅供人排查，gate 不解析它。
        File(dir, "elecon_build_profile.txt").writeText(
            "$label\nELECON_TRUST_PROFILE=$profile\n",
        )
    }
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

        // ADR-024 §2.3 护栏 3：DEV 侧载包用独立 applicationId 后缀。**结构性**防误发——
        // 换了 applicationId 的包不能作正牌 app 提交商店、不能覆盖用户机上的正牌安装、
        // 在设备上显示为另一个应用。versionName 后缀让「装的是哪个包」在关于页也一眼可见。
        if (sideloadEnabled) {
            applicationIdSuffix = ".devsideload"
            versionNameSuffix = "-devsideload"
        }
    }

    sourceSets {
        getByName("main") {
            // 护栏 4b：profile 标记随 APK 打包（assets/elecon_build_profile.txt）。
            assets.srcDir(buildProfileAssetsDir)
        }
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

// 标记文件必须先于合并资产生成，否则打进 APK 的会是上一次构建的陈旧标记
// （护栏 4b 的断言就会验错对象）。
tasks.withType<com.android.build.gradle.tasks.MergeSourceSetFolders>().configureEach {
    dependsOn(writeBuildProfileMarker)
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
