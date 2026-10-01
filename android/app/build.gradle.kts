import com.android.build.gradle.internal.api.ApkVariantOutputImpl
import org.jetbrains.kotlin.konan.properties.Properties
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val agpMajorVersion = com.android.Version.ANDROID_GRADLE_PLUGIN_VERSION
    .substringBefore('.')
    .toInt()
val builtInKotlinProperty = providers.gradleProperty("android.builtInKotlin").orNull
val isBuiltInKotlinEnabled = agpMajorVersion >= 9 &&
        (builtInKotlinProperty == null || builtInKotlinProperty.toBoolean())
if (!isBuiltInKotlinEnabled) {
    apply(plugin = "org.jetbrains.kotlin.android")
}

android {
    namespace = "com.example.piliplus"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.piliplus"
        minSdk = flutter.minSdkVersion
        targetSdk = 37
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    packagingOptions.jniLibs.useLegacyPackaging = true
    // libvlc-all 与 medialibrary-all 各自携带一份 libc++_shared.so(同一 NDK
    // 工具链产物), 取其一即可
    packagingOptions.jniLibs.pickFirsts += "lib/*/libc++_shared.so"

    val keyProperties = Properties().also {
        val properties = rootProject.file("key.properties")
        if (properties.exists())
            it.load(properties.inputStream())
    }

    val config = keyProperties.getProperty("storeFile")?.let {
        signingConfigs.create("release") {
            storeFile = file(it)
            storePassword = keyProperties.getProperty("storePassword")
            keyAlias = keyProperties.getProperty("keyAlias")
            keyPassword = keyProperties.getProperty("keyPassword")
            enableV1Signing = true
            enableV2Signing = true
        }
    }

    buildFeatures {
        if (project.hasProperty("dev")) {
            resValues = true
        }
    }

    buildTypes {
        all {
            signingConfig = config ?: signingConfigs["debug"]
        }
        release {
            if (project.hasProperty("dev")) {
                applicationIdSuffix = ".dev"
                resValue(
                    type = "string",
                    name = "app_name",
                    value = "PiliPlus dev",
                )
            }
//            proguardFiles(
//                getDefaultProguardFile("proguard-android-optimize.txt"),
//                "proguard-rules.pro"
//            )
        }
        debug {
            applicationIdSuffix = ".debug"
        }
    }

    applicationVariants.all {
        val variant = this
        variant.outputs.forEach { output ->
            (output as ApkVariantOutputImpl).versionCodeOverride = flutter.versionCode
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

// ---------------------------------------------------------------------------
// VR 版 libvlc(tool/libvlc-vr + .github/workflows/libvlc_vr.yml, docs §18):
// 官方 libvlc-all 3.7.6 AAR「换心」——仅 jni/arm64-v8a 下 libvlc/libvlcjni/
// libc++_shared 三个 .so 替换为打了 VR 补丁(vr-projection/vr-layout/
// vr-coverage/vr-eye + changeset 标记 piliplus-vr1)的构建, 其余 ABI 与
// classes/assets 保持官方原样。资产名固定(pvr1; 补丁迭代升 pvr2…), 由
// 滚动 release `libvlc-vr` 发布; 下载时用同名 .sha256 边车校验传输完整性,
// 校验通过才原子落盘(中断/损坏会自动重下)。
// ---------------------------------------------------------------------------
val libvlcVrAsset = "libvlc-all-3.7.6-pvr1-arm64-v8a.aar"
val libvlcVrBaseUrl =
    "https://github.com/OrientCOMPASS/PiliPlus/releases/download/libvlc-vr"
val libvlcVrDir = layout.buildDirectory.dir("libvlc-vr")

val downloadLibVlcVr = tasks.register("downloadLibVlcVr") {
    description = "Fetch the VR-patched libvlc-all AAR from the rolling libvlc-vr release"
    val aarFile = libvlcVrDir.map { it.file(libvlcVrAsset) }
    outputs.file(aarFile)
    doLast {
        val out = aarFile.get().asFile
        if (out.exists() && out.length() > 0) {
            logger.lifecycle("libvlc-vr AAR 已在本地: ${out.absolutePath}")
            return@doLast
        }
        out.parentFile.mkdirs()
        val tmp = File(out.parentFile, "${out.name}.part")
        val shaTmp = File(out.parentFile, "${out.name}.sha256.part")
        var lastError: Exception? = null
        for (attempt in 1..3) {
            try {
                tmp.delete()
                shaTmp.delete()
                ant.withGroovyBuilder {
                    "get"(
                        "src" to "$libvlcVrBaseUrl/$libvlcVrAsset",
                        "dest" to tmp,
                        "usessession" to false,
                        "retries" to 2,
                    )
                    "get"(
                        "src" to "$libvlcVrBaseUrl/$libvlcVrAsset.sha256",
                        "dest" to shaTmp,
                        "usessession" to false,
                        "retries" to 2,
                    )
                }
                lastError = null
                break
            } catch (e: Exception) {
                lastError = e
                logger.warn("libvlc-vr 下载第 $attempt 次失败: ${e.message}")
            }
        }
        if (lastError != null) {
            throw GradleException(
                "无法下载 VR 版 libvlc AAR: $libvlcVrBaseUrl/$libvlcVrAsset\n" +
                    "该资产由 .github/workflows/libvlc_vr.yml 构建并发布到滚动 release `libvlc-vr`。",
                lastError,
            )
        }
        val expected = shaTmp.readText().trim().split(Regex("\\s+")).first()
        val md = MessageDigest.getInstance("SHA-256")
        tmp.inputStream().use { input ->
            val buf = ByteArray(1 shl 20)
            var n: Int
            while (input.read(buf).also { n = it } > 0) {
                md.update(buf, 0, n)
            }
        }
        val actual = md.digest().joinToString("") { "%02x".format(it) }
        if (!actual.equals(expected, ignoreCase = true)) {
            tmp.delete()
            shaTmp.delete()
            throw GradleException(
                "libvlc-vr AAR sha256 校验失败: expected=$expected actual=$actual(已删除, 重跑构建即重试)",
            )
        }
        Files.move(tmp.toPath(), out.toPath(), StandardCopyOption.REPLACE_EXISTING)
        shaTmp.renameTo(File(out.parentFile, "${out.name}.sha256"))
        logger.lifecycle("libvlc-vr AAR 校验通过 sha256=$actual")
    }
}

dependencies {
    // 本地/局域网媒体的 VLC 引擎: VR 补丁定制版(上面 downloadLibVlcVr 拉取;
    // files(taskProvider) 会自动建立任务依赖, 打包前先完成下载+校验)。
    // medialibrary 不需要补丁, 仍用官方发布版。见 docs/piliplayer.md §18。
    implementation(files(downloadLibVlcVr))
    implementation("org.videolan.android:medialibrary-all:0.13.21")
}

