package com.hgonly.hgonly

import android.content.Intent
import android.media.MediaCodecList
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * 「自定义设备」里的「读取本机」靠这个通道拿到这台手机的身份。
 *
 *  - 红果 App 的 did / uid 存在它自己的私有目录里，普通 App 没有跨应用读取权限，
 *    只有 root 过的机器才拿得到（读 /data/data/com.phoenix.read/shared_prefs）。
 *  - 没 root 时退化成读取本机硬件档案 + 用 ANDROID_ID 派生一个稳定设备号，
 *    至少保证设备号「跟着这台机器走」，不会每次启动都变。
 *
 * 红果 App 自己的界面（关于页、个人信息收集设置）并不展示 did，所以读屏也拿不到。
 */
class MainActivity : FlutterActivity() {
    private val channelName = "hgonly/device"
    private val updateChannelName = "hgonly/update"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "readIdentity" -> {
                        try {
                            result.success(readIdentity())
                        } catch (t: Throwable) {
                            result.error("read_failed", t.message ?: "读取失败", null)
                        }
                    }
                    // TV 分支：按 SoC 分化解码策略所需的平台指纹。
                    "readTvDevice" -> {
                        try {
                            result.success(readTvDevice())
                        } catch (t: Throwable) {
                            result.error("read_failed", t.message ?: "读取失败", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        // 自动升级：Dart 下载好 APK 后调这里拉起系统安装器。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, updateChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // 下载前先查权限：没授权就先引导，别白下 40MB+ 的包再失败。
                    "hasInstallPermission" -> {
                        try {
                            val granted = Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                                packageManager.canRequestPackageInstalls()
                            result.success(granted)
                        } catch (t: Throwable) {
                            // 查不出来不要拦着下载，交给 installApk 报真实错误。
                            android.util.Log.w("hgonly-update", "hasInstallPermission failed", t)
                            result.success(true)
                        }
                    }
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("bad_args", "缺少 APK 路径", null)
                            return@setMethodCallHandler
                        }
                        // Android 8+ 若还没授予「安装未知应用」，先返回明确信号，
                        // 让 Dart 层引导用户去开权限——否则 ACTION_VIEW 会直接抛
                        // FileUriExposedException / ActivityNotFound，表现为「无法拉起安装器」。
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            !packageManager.canRequestPackageInstalls()
                        ) {
                            result.error("no_install_permission", "未授予「安装未知应用」权限", null)
                            return@setMethodCallHandler
                        }
                        try {
                            installApk(path)
                            result.success(true)
                        } catch (t: Throwable) {
                            android.util.Log.e("hgonly-update", "installApk failed path=$path", t)
                            // 把 FileProvider 路径失配单列出来：它的症状和「没授权」几乎一样
                            // （都是拉不起安装器），但修法完全不同，不能混在一起。
                            val msg = if (t is IllegalArgumentException) {
                                "APK 路径不在 FileProvider 声明范围内，请检查 file_paths.xml：${t.message}"
                            } else {
                                t.message ?: "拉起安装失败"
                            }
                            result.error("install_failed", msg, null)
                        }
                    }
                    // 跳系统「安装未知应用」授权页（Android 8+ 装包前可能需要）。
                    "openInstallPermissionSettings" -> {
                        try {
                            openInstallPermissionSettings()
                            result.success(true)
                        } catch (t: Throwable) {
                            result.error("settings_failed", t.message ?: "无法打开设置", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 用 FileProvider 把下载好的 APK 交给系统安装器。
     * authority 必须是 `${applicationId}.fileprovider`——tv flavor 的
     * applicationId 带 `.tv` 后缀，所以不能用写死的包名，取 applicationContext。
     */
    private fun installApk(path: String) {
        val file = File(path)
        if (!file.exists()) throw IllegalStateException("APK 不存在：$path")
        val uri = FileProvider.getUriForFile(
            this, "${applicationContext.packageName}.fileprovider", file
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    private fun openInstallPermissionSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                data = Uri.parse("package:$packageName")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
        } else {
            // 旧系统没有未知来源按应用授权，退回通用安全设置。
            startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            })
        }
    }

    private fun readIdentity(): Map<String, Any> {
        val metrics = resources.displayMetrics
        // 红果的 resolution 是「宽*高」，不能按长短边排，否则会跟真机对不上。
        val width = metrics.widthPixels
        val height = metrics.heightPixels
        val androidId = try {
            Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID) ?: ""
        } catch (t: Throwable) {
            ""
        }

        val rooted = hasRoot()
        var did = ""
        var uid = ""
        var source = "本机档案"

        if (rooted) {
            val prefs = readHongguoPrefs()
            did = prefs["device_id"].orEmpty()
            uid = prefs["user_id"].orEmpty()
            if (did.isNotEmpty() || uid.isNotEmpty()) {
                source = "红果 App 缓存"
            }
        }

        // 没 root 时读不到红果 App 私有目录里的 device_id。这里不再编造一个
        // 「看起来像」的号填进去——设备号是设备在服务端注册时分配的，编出来的
        // 号对取流没有任何帮助，反而会让档案看起来像伪造设备。宁可留空。
        val note = when {
            source == "红果 App 缓存" -> "已从红果 App 缓存读取设备号"
            !rooted -> "未 root，读不到红果 App 的设备号。请在红果 App 里打开「基础信息」页" +
                "（能看到 device_id 那一页），把 16 位数字填到下面。机型/系统已按本机自动填好。"
            else -> "已 root，但红果缓存里没有设备号（未登录过或数据被清），请在红果 App 的「基础信息」页查看"
        }

        return mapOf(
            "did" to did,
            "uid" to uid,
            "rooted" to rooted,
            "source" to source,
            "note" to note,
            "androidId" to androidId,
            "brand" to normalizeBrand(Build.BRAND, Build.MANUFACTURER),
            "rawBrand" to Build.BRAND,
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "osVersion" to Build.VERSION.RELEASE,
            "osApi" to Build.VERSION.SDK_INT,
            "resolution" to "$width*$height",
            "dpi" to metrics.densityDpi.toString(),
            "abi" to (Build.SUPPORTED_ABIS.firstOrNull() ?: ""),
        )
    }

    /**
     * TV 解码策略用的设备指纹（2026-11-07）。
     *
     * 结论收窄为「Amlogic tl1 的 MediaCodec HAL 回读 NV12 时 U/V 平面反读」：
     *  - 海尔 HRA972_TX_A / Amlogic tl1 / Android 9：硬解偏蓝，必须软解；
     *  - 创维 8H672_A5FMN / 海思 Hi3751V660 (huanglong) / Android 12：硬解颜色
     *    正常且 CPU 只有软解的约 39%，应当用硬解。
     * 所以策略必须读 ro.board.platform / ro.hardware / Build.*，不能靠「是不是 TV」
     * 一刀切，也不能只看有没有 HEVC 硬解码器。
     *
     * 用 `/system/bin/getprop` 一次性读全量属性再解析，避免反射访问
     * android.os.SystemProperties 被隐藏 API 限制挡住（Android 9 / 12 都验证过）。
     */
    private fun readTvDevice(): Map<String, Any> {
        val props = readAllSystemProperties()
        fun prop(vararg keys: String): String = keys
            .firstNotNullOfOrNull { key -> props[key]?.takeIf { it.isNotBlank() } }
            .orEmpty()

        return mapOf(
            "boardPlatform" to prop("ro.board.platform"),
            "hardware" to prop("ro.hardware", "ro.hardware.chipname"),
            "board" to prop("ro.product.board", "ro.product.vendor.board"),
            "product" to prop("ro.build.product", "ro.product.name"),
            "model" to Build.MODEL,
            "brand" to Build.BRAND,
            "manufacturer" to Build.MANUFACTURER,
            "release" to Build.VERSION.RELEASE,
            "sdkInt" to Build.VERSION.SDK_INT,
            "abi" to (Build.SUPPORTED_ABIS.firstOrNull() ?: ""),
            "hevcDecoders" to hevcDecoderNames(),
        )
    }

    private fun readAllSystemProperties(): Map<String, String> {
        val out = mutableMapOf<String, String>()
        try {
            val process = ProcessBuilder("/system/bin/getprop")
                .redirectErrorStream(true)
                .start()
            val pattern = Regex("""^\[([^]]+)]:\s*\[(.*)]$""")
            process.inputStream.bufferedReader().useLines { lines ->
                lines.forEach { line ->
                    val match = pattern.find(line) ?: return@forEach
                    out[match.groupValues[1]] = match.groupValues[2]
                }
            }
            if (!process.waitFor(3, TimeUnit.SECONDS)) process.destroy()
        } catch (_: Throwable) {
            // getprop 不可用时退回空表，Dart 侧会走「未知平台 → 保守软解」。
        }
        return out
    }

    /** 列出 HEVC 解码器名，用作规则匹配与实机取证（例如 OMX.amlogic.* / OMX.hisi.*）。 */
    private fun hevcDecoderNames(): List<String> = try {
        MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
            .filter { info ->
                !info.isEncoder && info.supportedTypes.any { type ->
                    type.equals("video/hevc", ignoreCase = true) ||
                        type.equals("video/hevc10", ignoreCase = true)
                }
            }
            .map { it.name }
            .sorted()
    } catch (_: Throwable) {
        emptyList()
    }

    /**
     * 归一化成红果 device_brand 用的厂商名：Redmi / POCO 都属于 xiaomi，
     * 不能直接拿 Build.BRAND 交上去，否则设备档案会自相矛盾。
     */
    private fun normalizeBrand(brand: String, manufacturer: String): String {
        val raw = "$brand $manufacturer".lowercase()
        return when {
            raw.contains("redmi") || raw.contains("xiaomi") || raw.contains("poco") -> "xiaomi"
            raw.contains("huawei") -> "harmonyos"
            raw.contains("honor") -> "honor"
            raw.contains("oneplus") -> "OnePlus"
            raw.contains("oppo") || raw.contains("realme") -> "coloros"
            raw.contains("vivo") || raw.contains("iqoo") -> "vivo"
            raw.contains("samsung") -> "samsung"
            raw.contains("meizu") -> "meizu"
            else -> brand.lowercase()
        }
    }

    /** root 可用时返回 true。超时或没有 su 都按「没有 root」处理。 */
    private fun hasRoot(): Boolean {
        return try {
            val process = ProcessBuilder("su", "-c", "id").redirectErrorStream(true).start()
            val finished = process.waitFor(2500, TimeUnit.MILLISECONDS)
            if (!finished) {
                process.destroy()
                return false
            }
            if (process.exitValue() != 0) return false
            process.inputStream.bufferedReader().readText().contains("uid=0")
        } catch (t: Throwable) {
            false
        }
    }

    /**
     * 从红果 App 的 SharedPreferences 里捞 did / uid。
     * key 名在不同版本里可能是 device_id / user_id / uid / user_id_str 等，这里都试一遍。
     */
    private fun readHongguoPrefs(): Map<String, String> {
        val dirs = listOf(
            "/data/data/com.phoenix.read/shared_prefs",
            "/data/user/0/com.phoenix.read/shared_prefs",
        )
        val entries = mutableMapOf<String, String>()
        val pattern = Regex("<string name=\"([A-Za-z0-9_]+)\">([^<]{1,64})</string>")

        for (dir in dirs) {
            val text = runRoot(
                "grep -rhoE '<string name=\"[A-Za-z0-9_]+\">[^<]{1,64}</string>' $dir 2>/dev/null"
            ) ?: continue
            if (text.isBlank()) continue
            for (match in pattern.findAll(text)) {
                val key = match.groupValues[1]
                val value = match.groupValues[2].trim()
                if (value.isNotEmpty()) entries.putIfAbsent(key, value)
            }
            if (entries.containsKey("device_id") || entries.containsKey("user_id")) break
        }

        val out = mutableMapOf<String, String>()
        for (key in listOf("device_id", "device_id_int", "deviceid")) {
            val value = entries[key] ?: continue
            if (value.matches(Regex("\\d{10,25}"))) {
                out["device_id"] = value
                break
            }
        }
        for (key in listOf("user_id", "user_id_str", "uid", "uid_str")) {
            val value = entries[key] ?: continue
            if (value.matches(Regex("\\d{3,25}"))) {
                out["user_id"] = value
                break
            }
        }
        return out
    }

    private fun runRoot(command: String): String? {
        return try {
            val process = ProcessBuilder("su", "-c", command).redirectErrorStream(true).start()
            val finished = process.waitFor(5000, TimeUnit.MILLISECONDS)
            if (!finished) {
                process.destroy()
                return null
            }
            process.inputStream.bufferedReader().readText()
        } catch (t: Throwable) {
            null
        }
    }

    /**
     * 没 root 时用 ANDROID_ID 派生一个 19 位、以 7 开头的稳定设备号。
     * 同一台机器每次算出来都一样，重装 App 也不会变（ANDROID_ID 在同一设备上稳定）。
     */
}
