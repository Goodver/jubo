plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------------------
// phone / tv 双 flavor（2026-11-07 TV 分支 P0）
//
// 手机主分支硬性只打 arm64-v8a；TV（海尔 HRA972_TX_A，Android 9 / API 28，
// ro.zygote=zygote32）是唯一例外，只能打 armeabi-v7a。
// 两条 ABI 规则必须互斥，尤其 packaging.jniLibs.excludes：
// 它决定 media_kit 等 AAR 自带的 4 套预编译 .so 最终留哪一套，
// 写反会得到「装得上、一播放就崩」的包。
//
// 构建时请显式传 -PhgOnlyTv=true / false；未传时按 Gradle task 名兜底。
// ---------------------------------------------------------------------------
val tvOverride = project.findProperty("hgOnlyTv")?.toString()?.lowercase()
val gradleTaskNames = gradle.startParameter.taskNames.map { it.lowercase() }
val isTvBuild = when (tvOverride) {
    "true" -> true
    "false" -> false
    else -> gradleTaskNames.any { name ->
        name.contains("tvrelease") || name.contains("tvdebug") ||
            name.contains("assembletv") || name.contains(":tv")
    }
}
val jniLibExcludes = if (isTvBuild) {
    listOf("lib/x86/**", "lib/x86_64/**", "lib/arm64-v8a/**", "lib/armeabi/**")
} else {
    listOf("lib/x86/**", "lib/x86_64/**", "lib/armeabi-v7a/**", "lib/armeabi/**")
}
logger.lifecycle("[hgonly] ABI profile = ${if (isTvBuild) "tv/armeabi-v7a" else "phone/arm64-v8a"}; jniLibs excludes = $jniLibExcludes")

android {
    namespace = "com.hgonly.hgonly"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.hgonly.hongguo"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // ABI 决策已上移到 productFlavors；这里不再写死 arm64。
    }

    flavorDimensions += "device"
    productFlavors {
        create("phone") {
            dimension = "device"
            ndk { abiFilters += listOf("arm64-v8a") }
        }
        create("tv") {
            dimension = "device"
            applicationIdSuffix = ".tv"
            versionNameSuffix = "-tv"
            ndk { abiFilters += listOf("armeabi-v7a") }
        }
    }

    // 只留当前 flavor 的 ABI：media_kit 等 AAR 自带 4 个 ABI 的预编译 .so，
    // abiFilters 无法把这些第三方 jniLibs 全部过滤掉，需在打包阶段显式排除。
    packaging {
        jniLibs {
            excludes.addAll(jniLibExcludes)
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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

dependencies {
    // 自动升级用 FileProvider 暴露下载好的 APK 给系统安装器。
    implementation("androidx.core:core-ktx:1.13.1")
}
