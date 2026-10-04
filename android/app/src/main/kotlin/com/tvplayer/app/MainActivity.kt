package com.tvplayer.app

import android.app.UiModeManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.os.storage.StorageManager
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

class MainActivity : FlutterActivity() {

    private val deviceChannelName = "tvplayer/device"
    private val storageChannelName = "tvplayer/storage"
    private val downloadChannelName = "tvplayer/download"
    private val cryptoChannelName = "tvplayer/crypto"
    private val updateChannelName = "tvplayer/update"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ---- tvplayer/device：设备档位 ----------------------------------------
        //
        // 只做一件事：把「是不是电视 / 有没有触摸屏」告诉 Dart 侧。
        // Dart 侧据此在「电视档」和「手机档」之间切换界面参数。
        // 判定放在原生侧是因为 Dart 拿不到 UiModeManager / 系统特性，
        // 而按逻辑分辨率猜会把 xhdpi 的 1080p 电视误判成手机。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, deviceChannelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "deviceInfo") {
                    result.success(
                        mapOf(
                            "isTelevision" to isTelevision(),
                            "hasTouchScreen" to hasTouchScreen()
                        )
                    )
                } else {
                    result.notImplemented()
                }
            }

        // ---- tvplayer/storage：下载目录 ---------------------------------------
        //
        // 「所有文件访问权限」只有原生侧能查 / 能申请；剩余空间也只能靠 StatFs。
        // Dart 侧拿到这些之后用 dart:io 直接读写目录 —— 比走 SAF 的
        // ContentResolver 快得多，也不用为每个文件建一次管道。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, storageChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasAllFilesAccess" -> result.success(hasAllFilesAccess())
                    "requestAllFilesAccess" -> {
                        requestAllFilesAccess()
                        result.success(null)
                    }
                    "storageRoots" -> result.success(storageRoots())
                    "freeSpaceBytes" -> {
                        val path = call.argument<String>("path")
                        result.success(if (path.isNullOrEmpty()) -1L else freeSpaceBytes(path))
                    }
                    else -> result.notImplemented()
                }
            }

        // ---- tvplayer/download：前台服务 --------------------------------------
        //
        // 只负责「保活 + 通知」。真正的下载在 Dart 侧跑，这里不碰下载逻辑。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, downloadChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "post" -> {
                        DownloadForegroundService.post(
                            this,
                            call.argument<String>("title") ?: "正在下载",
                            call.argument<String>("text") ?: "",
                            (call.argument<Number>("progress"))?.toInt() ?: -1,
                            (call.argument<Number>("max"))?.toInt() ?: 0
                        )
                        result.success(null)
                    }
                    "stop" -> {
                        DownloadForegroundService.stop(this)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // ---- tvplayer/crypto：AES-128-CBC 解密 ---------------------------------
        //
        // 加密 HLS 的每个分片是独立的 AES-128-CBC 密文，**不解密就没法合并**，
        // 用户就拿不到他要的单文件。Dart 侧没有可用的 AES 实现
        // （package:crypto 只有哈希和 HMAC），而 Android 自带 javax.crypto ——
        // 走系统实现比引一个纯 Dart 密码库更快也更可靠（有硬件加速）。
        //
        // 逐个分片调用一次，一集几十次，开销可以忽略。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, cryptoChannelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "aesCbcDecrypt") {
                    try {
                        val key = call.argument<ByteArray>("key")
                        val iv = call.argument<ByteArray>("iv")
                        val data = call.argument<ByteArray>("data")
                        if (key == null || iv == null || data == null) {
                            result.error("BAD_ARGS", "key / iv / data 都不能为空", null)
                        } else {
                            result.success(aesCbcDecrypt(key, iv, data))
                        }
                    } catch (e: Exception) {
                        // 交给 Dart 侧决定怎么办：它会退回「保留分片 + local.m3u8」，
                        // 而不是把已经下好的整集丢掉。
                        result.error("DECRYPT_FAILED", e.message ?: e.toString(), null)
                    }
                } else {
                    result.notImplemented()
                }
            }

        // ---- tvplayer/update：自动更新 ----------------------------------------
        //
        // 「读包信息」和「把包交给系统安装器」这两件事只有原生侧能做：
        // 前者要 PackageManager 解析 APK 的 manifest，后者要 FileProvider 把
        // 私有目录里的文件以 content:// 形式临时授权出去（Android 7 起
        // file:// 路径会直接抛 FileUriExposedException）。
        //
        // 下载、比对版本、决定装不装，全在 Dart 侧。这里只当「手」。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, updateChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "currentVersion" -> result.success(currentVersion())
                    "appFilesDir" -> result.success(filesDir.absolutePath)
                    "canInstallPackages" -> result.success(canInstallPackages())
                    "requestInstallPermission" -> {
                        requestInstallPermission()
                        result.success(null)
                    }
                    "apkInfo" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("BAD_ARGS", "path 不能为空", null)
                        } else {
                            try {
                                result.success(apkInfo(path))
                            } catch (e: Exception) {
                                result.error("APK_UNREADABLE", e.message ?: e.toString(), null)
                            }
                        }
                    }
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("BAD_ARGS", "path 不能为空", null)
                        } else {
                            result.success(installApk(path))
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// AES-128-CBC 解密 + 自己剥 PKCS#7 填充。
    ///
    /// 为什么用 `NoPadding` 再手动剥、而不是直接 `PKCS5Padding`：HLS 规范要求分片
    /// 加密时填充，但实际见过不填充的打包器。用 try/catch 去猜既慢又不稳；
    /// 手动判据更干净，而且下面能借 TS 的结构做**确定性**判定。
    private fun aesCbcDecrypt(key: ByteArray, iv: ByteArray, data: ByteArray): ByteArray {
        require(key.size == 16) { "AES-128 密钥必须是 16 字节，实际 ${key.size}" }
        require(iv.size == 16) { "IV 必须是 16 字节，实际 ${iv.size}" }
        require(data.isNotEmpty() && data.size % 16 == 0) {
            "密文长度 ${data.size} 不是 16 的正整数倍"
        }
        val cipher = Cipher.getInstance("AES/CBC/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(key, "AES"),
            IvParameterSpec(iv)
        )
        val plain = cipher.doFinal(data)

        // TS 分片的长度必然是 188 的整数倍（MPEG-TS 就是一串 188 字节的包，
        // 切分点一定落在包边界上）。这条不变式让「到底有没有填充」变成**确定性**
        // 判断，而不是靠「末尾字节恰好落在 1..16」这种 1/256 会误判的概率判据 ——
        // 误判一次就会把好数据砍掉一个字节。
        val looksLikeTs = plain.size >= 188 && (plain[0].toInt() and 0xff) == 0x47
        if (looksLikeTs) {
            if (plain.size % 188 == 0) return plain          // 本来就没填充
            val p = plain[plain.size - 1].toInt() and 0xff
            if (p in 1..16 && plain.size > p && (plain.size - p) % 188 == 0) {
                return plain.copyOf(plain.size - p)
            }
        }

        // 非 TS（fMP4 等）退回 PKCS#7 判据：末尾 p 个字节都等于 p 就是填充。
        val pad = plain[plain.size - 1].toInt() and 0xff
        if (pad in 1..16 && pad <= plain.size) {
            var allEqual = true
            for (i in plain.size - pad until plain.size) {
                if ((plain[i].toInt() and 0xff) != pad) {
                    allEqual = false
                    break
                }
            }
            if (allEqual) return plain.copyOf(plain.size - pad)
        }
        return plain
    }

    // --- 自动更新 -----------------------------------------------------------

    /// 读包信息时用的 flag。
    ///
    /// API 28 之前没有 `GET_SIGNING_CERTIFICATES`，只能用已废弃的 `GET_SIGNATURES`。
    /// 这里整体抑制 DEPRECATION，而不是在 `else` 分支上挂一个表达式注解 ——
    /// 表达式上的注解在 Kotlin 里能写但容易在换编译器版本时出意外。
    @Suppress("DEPRECATION")
    private fun packageInfoFlags(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }

    /// 读某个已安装包的信息。
    ///
    /// API 33 起旧的 `getPackageInfo(String, Int)` 被废弃，换成 `PackageInfoFlags`。
    /// 两个重载都要留着，因为目标设备里既有 Android 9 也有 Android 14。
    @Suppress("DEPRECATION")
    private fun installedPackageInfo(name: String, flags: Int): PackageInfo =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageInfo(
                name,
                PackageManager.PackageInfoFlags.of(flags.toLong())
            )
        } else {
            packageManager.getPackageInfo(name, flags)
        }

    /// 当前安装的这个包的版本。
    private fun currentVersion(): Map<String, Any?> {
        val info = installedPackageInfo(packageName, 0)
        return mapOf(
            "versionCode" to versionCodeOf(info),
            "versionName" to info.versionName
        )
    }

    /// 有没有「安装未知应用」的权限。
    ///
    /// Android 8 起这是个特殊权限，App 不能自己弹框申请，只能跳设置页。
    /// 8 以下没有这个概念，一律返回 true。
    private fun canInstallPackages(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }

    private fun requestInstallPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                    data = Uri.parse("package:$packageName")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            )
        } catch (e: Exception) {
            // 个别 ROM 没有「按应用」的那个页面，退回列表页。
            try {
                startActivity(
                    Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            } catch (e2: Exception) {
                // 都打不开就算了：Dart 侧会把原因显示给用户。
            }
        }
    }

    /// 解析一个 APK 文件的 manifest，**不安装**。
    ///
    /// 这一步是「下载完先验包」：包名不是自己、或者签名和已装的不一样，
    /// 都要在这里拦下来。否则丢给系统安装器只会得到一个
    /// `INSTALL_FAILED_UPDATE_INCOMPATIBLE`，用户完全看不出是哪里不对。
    ///
    /// `getPackageArchiveInfo(String, Int)` 在 API 35+ 也被废弃了，这里一并抑制。
    @Suppress("DEPRECATION")
    private fun apkInfo(path: String): Map<String, Any?> {
        val file = File(path)
        if (!file.exists() || file.length() == 0L) {
            throw IllegalArgumentException("安装包不存在或大小为 0：$path")
        }
        val flags = packageInfoFlags()
        val info = packageManager.getPackageArchiveInfo(path, flags)
            ?: throw IllegalArgumentException("读不出这个文件的包信息，可能不是 APK，或者下载不完整")

        val label = info.applicationInfo?.let { ai ->
            // getApplicationLabel 默认按 sourceDir 去读资源。归档 APK 必须先
            // 把这个路径补上，否则拿到的是 null 或者空串。
            ai.sourceDir = path
            ai.publicSourceDir = path
            try {
                packageManager.getApplicationLabel(ai).toString()
            } catch (e: Exception) {
                null
            }
        }

        val archiveSigners = signerHashes(info)
        val installedSigners = try {
            signerHashes(installedPackageInfo(packageName, flags))
        } catch (e: Exception) {
            emptySet<String>()
        }

        return mapOf(
            "packageName" to info.packageName,
            "versionCode" to versionCodeOf(info),
            "versionName" to info.versionName,
            "appLabel" to label,
            "sizeBytes" to file.length(),
            "isSamePackage" to (info.packageName == packageName),
            // 两边都要拿到签名、且至少有一个公钥指纹相同，才算「同一个签名」。
            // 拿不到就报 false，让 Dart 侧按「无法确认」拦下来 —— 放行一个
            // 签名不明的包去覆盖安装，风险比多问一句大得多。
            "sameSigner" to (
                archiveSigners.isNotEmpty() &&
                    installedSigners.isNotEmpty() &&
                    archiveSigners.any { installedSigners.contains(it) }
                ),
            "signerUnknown" to (archiveSigners.isEmpty() || installedSigners.isEmpty())
        )
    }

    /// 把 APK 交给系统安装界面。真正「装」的动作是系统做的，这里只负责递过去。
    private fun installApk(path: String): Map<String, Any?> {
        val file = File(path)
        if (!file.exists() || file.length() == 0L) {
            return mapOf(
                "ok" to false,
                "reason" to "FILE_MISSING",
                "message" to "安装包不存在或大小为 0，请重新下载"
            )
        }
        if (!canInstallPackages()) {
            return mapOf(
                "ok" to false,
                "reason" to "NO_PERMISSION",
                "message" to "系统还没允许本应用安装其他应用"
            )
        }
        return try {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                // FileProvider 是 exported=false，不显式授予这个临时读权限，
                // 系统安装器打不开这个 content:// URI。
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            mapOf("ok" to true, "reason" to "OK", "message" to "已打开系统安装界面")
        } catch (e: IllegalArgumentException) {
            // FileProvider 在 file_paths.xml 里找不到匹配的目录时抛的就是这个。
            mapOf(
                "ok" to false,
                "reason" to "PROVIDER_PATH",
                "message" to "安装包不在可共享的目录里：${e.message}"
            )
        } catch (e: ActivityNotFoundException) {
            mapOf(
                "ok" to false,
                "reason" to "NO_INSTALLER",
                "message" to "这台设备上找不到能安装 APK 的程序"
            )
        } catch (e: Exception) {
            mapOf(
                "ok" to false,
                "reason" to "UNKNOWN",
                "message" to (e.message ?: e.toString())
            )
        }
    }

    /// 取一个包的签名公钥指纹集合。
    ///
    /// API 28 起用 `signingInfo`：多签名取 `apkContentsSigners`，单签名取
    /// `signingCertificateHistory`（密钥轮换时它会带上旧证书，正好用于比对）。
    ///
    /// 返回空集合表示「读不出来」。调用方必须把它当成「无法确认」，而不是放行。
    @Suppress("DEPRECATION")
    private fun signerHashes(info: PackageInfo): Set<String> {
        val out = mutableSetOf<String>()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val si = info.signingInfo ?: return out
                val signers =
                    if (si.hasMultipleSigners()) si.apkContentsSigners
                    else si.signingCertificateHistory
                for (s in signers) out.add(sha256Hex(s.toByteArray()))
            } else {
                val sigs = info.signatures
                if (sigs != null) {
                    for (s in sigs) out.add(sha256Hex(s.toByteArray()))
                }
            }
        } catch (e: Exception) {
            // 读不出来就返回空集合，调用方按「签名无法确认」处理。
        }
        return out
    }

    private fun sha256Hex(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        val sb = StringBuilder(digest.size * 2)
        for (b in digest) sb.append(String.format("%02x", b))
        return sb.toString()
    }

    private fun versionCodeOf(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            legacyVersionCode(info)
        }

    @Suppress("DEPRECATION")
    private fun legacyVersionCode(info: PackageInfo): Long = info.versionCode.toLong()

    // --- 设备档位 -----------------------------------------------------------

    /// 电视判定：系统当前 UI 模式是电视，或者声明了 leanback / television 特性。
    private fun isTelevision(): Boolean {
        val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        if (uiModeManager != null &&
            uiModeManager.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
        ) {
            return true
        }
        val pm = packageManager
        return pm.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
            pm.hasSystemFeature(PackageManager.FEATURE_TELEVISION)
    }

    private fun hasTouchScreen(): Boolean =
        packageManager.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN)

    // --- 存储 ---------------------------------------------------------------

    private fun hasAllFilesAccess(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            // Android 11 之前没有「所有文件访问权限」这个概念，写外部存储靠
            // READ/WRITE_EXTERNAL_STORAGE 运行时权限。本 App 的实际目标设备都在
            // Android 11+，这里保守返回 false，让 Dart 侧退回应用私有目录 ——
            // 宁可少一个功能，也不要为了老系统再引一套运行时权限流程。
            false
        }
    }

    private fun requestAllFilesAccess() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        try {
            startActivity(
                Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                    data = Uri.parse("package:$packageName")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            )
        } catch (e: Exception) {
            // 部分 ROM 没有「按应用」的这个页面，退回「所有应用」的列表页。
            try {
                startActivity(
                    Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            } catch (e2: Exception) {
                // 都打不开就算了：Dart 侧会退回应用私有目录，下载照样能用。
            }
        }
    }

    /// 可用的存储根（主存储 + SD 卡），给目录浏览器当起点。
    private fun storageRoots(): List<String> {
        val out = mutableListOf<String>()
        try {
            val sm = getSystemService(Context.STORAGE_SERVICE) as? StorageManager
            if (sm != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                for (volume in sm.storageVolumes) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        // getDirectory() 需要 API 30。未挂载的卷会返回 null，跳过。
                        volume.directory?.absolutePath?.let { out.add(it) }
                    }
                }
            }
        } catch (e: Exception) {
            // 忽略：下面有兜底。
        }
        if (out.isEmpty()) {
            @Suppress("DEPRECATION")
            val legacyRoot = Environment.getExternalStorageDirectory().absolutePath
            out.add(legacyRoot)
        }
        return out.distinct()
    }

    private fun freeSpaceBytes(path: String): Long {
        return try {
            StatFs(path).availableBytes
        } catch (e: Exception) {
            -1L
        }
    }
}
