package com.brucetso.sendhere

import android.content.ContentValues
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {
    private val fileChannel = "sendhere/mobile_file"

    /**
     * The name other devices see, matching what iOS and macOS report
     * (`UIDevice.name` / `Host.localizedName`): the name the owner gave the
     * phone, not a build identifier.
     *
     * `Build.MODEL` cannot be used as-is: Xiaomi/Redmi/POCO ship the internal
     * part number there (this phone reports "24069RA21C" for a Redmi Turbo 3),
     * which means nothing to the person on the other end.
     */
    private fun deviceName(): String {
        try {
            val configured = Settings.Global.getString(
                contentResolver, Settings.Global.DEVICE_NAME)
            if (!configured.isNullOrBlank()) return configured.trim()
        } catch (_: Exception) {
            // Older releases have no DEVICE_NAME; fall through to the model.
        }
        val model = Build.MODEL.orEmpty().trim()
        // Year-week codes such as 24069RA21C / 2312DRA50C. Samsung's SM-S918B
        // and Pixel's "Pixel 8 Pro" start with letters and pass through.
        val isPartNumber = Regex("^\\d{4,6}[A-Z][A-Z0-9]*$").matches(model)
        if (model.isNotEmpty() && !isPartNumber) return model
        // Prefer the line brand over the parent company: Redmi over Xiaomi.
        val brand = Build.BRAND.orEmpty().ifBlank { Build.MANUFACTURER.orEmpty() }
        val readable = brand.trim().replaceFirstChar { it.uppercase() }
        return if (readable.isEmpty()) "Android 设备" else "$readable 手机"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sendhere/device_name")
            .setMethodCallHandler { call, result ->
                if (call.method == "get") {
                    result.success(deviceName())
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, fileChannel)
            .setMethodCallHandler { call, result ->
                val path = call.argument<String>("path")
                if (path.isNullOrBlank()) {
                    result.error("invalid_path", "未提供文件路径", null)
                    return@setMethodCallHandler
                }
                val file = File(path)
                if (!file.exists()) {
                    result.error("file_missing", "文件已不存在", path)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "open" -> openFile(file, result)
                    "saveImage" -> saveImage(file, result)
                    "publishToDownloads" -> publishToDownloads(file, result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun openFile(file: File, result: MethodChannel.Result) {
        try {
            // Received files live in Flutter's documents directory, which is not
            // guaranteed to be a FileProvider root. Share a short-lived cache copy
            // instead of exposing a broad filesystem root.
            val shareFile = File(cacheDir, "shared/${file.name}")
            shareFile.parentFile?.mkdirs()
            file.copyTo(shareFile, overwrite = true)
            val uri = FileProvider.getUriForFile(
                this, "$packageName.fileprovider", shareFile)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, contentResolver.getType(uri) ?: "application/octet-stream")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(intent, "打开文件"))
            result.success(null)
        } catch (error: Exception) {
            result.error("open_failed", error.message ?: "无法打开文件", null)
        }
    }

    /**
     * Makes a received file visible in the system Files app under
     * Download/SendHere and returns the path the app should keep using.
     * - Android 11+: moves it (the app may read files it created in shared
     *   storage by path), so the file survives an uninstall.
     * - Android 10: shared storage is not path-readable, so a copy is
     *   published and the private original stays the in-app reference.
     * - Android 9 and below: would need a storage permission; keep private.
     */
    private fun publishToDownloads(file: File, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.success(file.path)
            return
        }
        Thread {
            try {
                val mime = android.webkit.MimeTypeMap.getSingleton()
                    .getMimeTypeFromExtension(file.extension.lowercase())
                    ?: "application/octet-stream"
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, file.name)
                    put(MediaStore.Downloads.MIME_TYPE, mime)
                    put(MediaStore.Downloads.RELATIVE_PATH,
                        Environment.DIRECTORY_DOWNLOADS + "/SendHere")
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
                val uri = contentResolver.insert(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                    ?: throw IllegalStateException("无法创建下载文件")
                try {
                    contentResolver.openOutputStream(uri)?.use { output ->
                        FileInputStream(file).use { input -> input.copyTo(output) }
                    } ?: throw IllegalStateException("无法写入下载文件")
                    values.clear()
                    values.put(MediaStore.Downloads.IS_PENDING, 0)
                    contentResolver.update(uri, values, null, null)
                } catch (error: Exception) {
                    contentResolver.delete(uri, null, null)
                    throw error
                }
                var finalPath = file.path
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    // MediaStore may rename on conflict ("a (1).pdf"); ask it.
                    @Suppress("DEPRECATION")
                    val published = contentResolver.query(
                        uri, arrayOf(MediaStore.MediaColumns.DATA), null, null, null
                    )?.use { cursor ->
                        if (cursor.moveToFirst()) cursor.getString(0) else null
                    }
                    if (published != null && File(published).canRead()) {
                        file.delete()
                        finalPath = published
                    }
                }
                runOnUiThread { result.success(finalPath) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("publish_failed", error.message ?: "无法保存到下载目录", null)
                }
            }
        }.start()
    }

    private fun saveImage(file: File, result: MethodChannel.Result) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, file.name)
                    put(MediaStore.Images.Media.MIME_TYPE, contentResolver.getType(
                        FileProvider.getUriForFile(this@MainActivity, "$packageName.fileprovider", file)
                    ) ?: "image/jpeg")
                    put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/SendHere")
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }
                val uri = contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                    ?: throw IllegalStateException("无法创建相册文件")
                contentResolver.openOutputStream(uri)?.use { output ->
                    FileInputStream(file).use { input -> input.copyTo(output) }
                } ?: throw IllegalStateException("无法写入相册文件")
                values.clear()
                values.put(MediaStore.Images.Media.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
            } else {
                val target = File(
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
                    "SendHere/${file.name}")
                target.parentFile?.mkdirs()
                file.copyTo(target, overwrite = true)
                MediaScannerConnection.scanFile(this, arrayOf(target.path), null, null)
            }
            result.success(null)
        } catch (error: Exception) {
            result.error("save_failed", error.message ?: "无法保存图片", null)
        }
    }
}
