package com.example.english_point_reading

import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val updateWorker = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "xiangshao_reader/app_updates")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInstalledApp" -> respond(result) {
                        val info = installedPackage()
                        val code = versionCode(info)
                        mapOf(
                            "versionName" to (info.versionName ?: ""),
                            "versionCode" to code,
                            // Flutter's split-per-ABI codes use ABI * 1000 + pubspec build.
                            "buildNumber" to if (code >= 1000) code % 1000 else code,
                            "packageName" to packageName,
                            "abis" to Build.SUPPORTED_ABIS.toList(),
                            "sdkInt" to Build.VERSION.SDK_INT,
                        )
                    }
                    "getDownloadDirectory" -> respond(result) {
                        updateDirectory().absolutePath
                    }
                    "canInstallPackages" -> respond(result) { canInstallPackages() }
                    "openInstallPermissionSettings" -> respond(result) {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:$packageName"),
                                ),
                            )
                        }
                        null
                    }
                    "validateApk", "installApk" -> validateOnWorker(call, result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun respond(result: MethodChannel.Result, action: () -> Any?) {
        try {
            result.success(action())
        } catch (error: Exception) {
            result.error("UPDATE_PLATFORM_ERROR", error.message, null)
        }
    }

    private fun updateDirectory(): File = File(cacheDir, "updates").apply {
        check(isDirectory || mkdirs()) { "Unable to create private update directory" }
    }

    private fun canInstallPackages(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()

    @Suppress("DEPRECATION")
    private fun signingFlags(): Int = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        PackageManager.GET_SIGNING_CERTIFICATES
    } else {
        PackageManager.GET_SIGNATURES
    }

    @Suppress("DEPRECATION")
    private fun installedPackage(): PackageInfo =
        packageManager.getPackageInfo(packageName, signingFlags())

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode
        else info.versionCode.toLong()

    @Suppress("DEPRECATION")
    private fun signingFingerprints(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners
        } else {
            info.signatures
        }
        check(!signatures.isNullOrEmpty()) { "APK signing certificate is unavailable" }
        return signatures.map { sha256(it.toByteArray()) }.toSet()
    }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun fileSha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    @Suppress("DEPRECATION")
    private fun validateApk(call: MethodCall): File {
        val path = requireNotNull(call.argument<String>("path")) { "APK path is missing" }
        val expectedSize = requireNotNull(call.argument<Number>("size")) { "APK size is missing" }.toLong()
        val expectedVersion = requireNotNull(call.argument<Number>("versionCode")) {
            "APK version is missing"
        }.toLong()
        val expectedHash = requireNotNull(call.argument<String>("sha256")) { "APK checksum is missing" }
        val file = File(path).canonicalFile
        val root = updateDirectory().canonicalFile
        check(file.parentFile == root && file.isFile && file.extension == "apk") {
            "APK must be in the private updates directory"
        }
        check(expectedSize > 0 && file.length() == expectedSize) { "APK size does not match" }
        check(Regex("^[a-fA-F0-9]{64}$").matches(expectedHash)) { "Invalid APK checksum" }
        check(fileSha256(file).equals(expectedHash, ignoreCase = true)) { "APK checksum does not match" }
        val candidate = packageManager.getPackageArchiveInfo(file.absolutePath, signingFlags())
            ?: error("APK could not be parsed")
        val installed = installedPackage()
        check(candidate.packageName == packageName) { "APK belongs to a different application" }
        check(versionCode(candidate) == expectedVersion && expectedVersion > versionCode(installed)) {
            "APK version must be newer than the installed application"
        }
        check(signingFingerprints(candidate) == signingFingerprints(installed)) {
            "APK signing identity does not match this application"
        }
        if (Build.VERSION.SDK_INT >= 36) {
            // Also verify the APK signing block on platforms exposing this API.
            val verified = PackageManager.getVerifiedSigningInfo(file.absolutePath, 2)
            check(verified.apkContentsSigners.map { sha256(it.toByteArray()) }.toSet() ==
                signingFingerprints(installed)) { "APK signing verification failed" }
        }
        return file
    }

    private fun validateOnWorker(call: MethodCall, result: MethodChannel.Result) {
        updateWorker.execute {
            try {
                val file = validateApk(call)
                mainHandler.post {
                    respond(result) {
                        if (call.method == "installApk") {
                            check(canInstallPackages()) { "Install permission is required" }
                            val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                clipData = ClipData.newRawUri("APK update", uri)
                            }
                            startActivity(intent)
                        }
                        null
                    }
                }
            } catch (error: Exception) {
                mainHandler.post { result.error("INVALID_UPDATE_APK", error.message, null) }
            }
        }
    }

    override fun onDestroy() {
        updateWorker.shutdownNow()
        super.onDestroy()
    }
}
