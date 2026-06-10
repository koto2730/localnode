package com.ictglab.localnode


import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.documentfile.provider.DocumentFile

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.ictglab.localnode/saf_storage"
    private val FOLDER_CHANNEL = "com.ictglab.localnode/folder"
    private val REQUEST_CODE_OPEN_DOCUMENT_TREE = 42
    private var pendingResult: MethodChannel.Result? = null // Dart側への結果を保持するため

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler {
            call, result ->
            when (call.method) {
                "requestSafDirectory" -> {
                    pendingResult = result // 結果を一時的に保持
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                        flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                    }
                    startActivityForResult(intent, REQUEST_CODE_OPEN_DOCUMENT_TREE)
                }
                "listFiles" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString == null) {
                        result.error("ARGUMENT_ERROR", "URI is required.", null)
                        return@setMethodCallHandler
                    }
                    val treeUri = Uri.parse(uriString)
                    val documentFile = DocumentFile.fromTreeUri(context, treeUri)
                    if (documentFile == null || !documentFile.isDirectory) {
                        result.error("FILE_NOT_FOUND", "Directory not found or not a directory.", null)
                        return@setMethodCallHandler
                    }

                    val fileList = documentFile.listFiles().filter { it.isFile }.map { file ->
                        mapOf(
                            "name" to file.name,
                            "uri" to file.uri.toString(),
                            "size" to file.length(),
                            "modified" to file.lastModified()
                        )
                    }
                    result.success(fileList)
                }
                "createFile" -> {
                    val uriString = call.argument<String>("uri")
                    val filename = call.argument<String>("filename")
                    val mimeType = call.argument<String>("mimeType")
                    val bytes = call.argument<ByteArray>("bytes")

                    if (uriString == null || filename == null || mimeType == null || bytes == null) {
                        result.error("ARGUMENT_ERROR", "uri, filename, mimeType, and bytes are required.", null)
                        return@setMethodCallHandler
                    }

                    val treeUri = Uri.parse(uriString)
                    val parentDocument = DocumentFile.fromTreeUri(context, treeUri)
                    
                    val newFile = parentDocument?.createFile(mimeType, filename)
                    if (newFile == null) {
                        result.error("CREATE_FAILED", "Failed to create file.", null)
                        return@setMethodCallHandler
                    }

                    try {
                        context.contentResolver.openOutputStream(newFile.uri)?.use { outputStream ->
                            outputStream.write(bytes)
                        }
                        result.success(newFile.uri.toString())
                    } catch (e: Exception) {
                        // 作成に失敗した場合は、不完全なファイルを削除しようと試みる
                        newFile.delete()
                        result.error("WRITE_FAILED", "Failed to write to file: ${e.message}", null)
                    }
                }
                "readFile" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString == null) {
                        result.error("ARGUMENT_ERROR", "URI is required.", null)
                        return@setMethodCallHandler
                    }

                    try {
                        val fileUri = Uri.parse(uriString)
                        context.contentResolver.openInputStream(fileUri)?.use { inputStream ->
                            val bytes = inputStream.readBytes()
                            result.success(bytes)
                        } ?: result.error("READ_FAILED", "Failed to open input stream.", null)
                    } catch (e: Exception) {
                        result.error("READ_FAILED", "Failed to read file: ${e.message}", null)
                    }
                }
                "getFileSize" -> {
                    // #244 review: sniff の前にサイズだけ問い合わせるため。
                    // 巨大ファイルで readFile (= 全読み) に到達させない。
                    val uriString = call.argument<String>("uri")
                    if (uriString == null) {
                        result.error("ARGUMENT_ERROR", "URI is required.", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val fileUri = Uri.parse(uriString)
                        val df = DocumentFile.fromSingleUri(context, fileUri)
                        if (df == null || !df.exists()) {
                            result.error("FILE_NOT_FOUND", "File not found.", null)
                            return@setMethodCallHandler
                        }
                        result.success(df.length())
                    } catch (e: Exception) {
                        result.error("SIZE_FAILED", "Failed to get size: ${e.message}", null)
                    }
                }
                "resolvePath" -> {
                    // #209: 相対パスを SAF ツリー配下の document URI に解決する
                    val uriString = call.argument<String>("uri")
                    val relPath = call.argument<String>("path")
                    if (uriString == null || relPath == null) {
                        result.error("ARGUMENT_ERROR", "uri and path are required.", null)
                        return@setMethodCallHandler
                    }
                    // パストラバーサル防止
                    val segments = relPath.split('/', '\\').filter { it.isNotEmpty() }
                    if (segments.isEmpty() || segments.any { it == ".." || it == "." } || segments.size > 16) {
                        result.error("INVALID_PATH", "Invalid relative path.", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val treeUri = Uri.parse(uriString)
                        var current: DocumentFile? = DocumentFile.fromTreeUri(context, treeUri)
                        for (seg in segments) {
                            val next = current?.findFile(seg)
                            if (next == null || !next.exists()) {
                                result.error("NOT_FOUND", "Segment not found: $seg", null)
                                return@setMethodCallHandler
                            }
                            current = next
                        }
                        val target = current
                        if (target == null || !target.isFile) {
                            result.error("NOT_FILE", "Resolved entry is not a file.", null)
                            return@setMethodCallHandler
                        }
                        result.success(target.uri.toString())
                    } catch (e: Exception) {
                        result.error("RESOLVE_FAILED", "Failed to resolve path: ${e.message}", null)
                    }
                }
                "deleteFile" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString == null) {
                        result.error("ARGUMENT_ERROR", "URI is required.", null)
                        return@setMethodCallHandler
                    }

                    try {
                        val fileUri = Uri.parse(uriString)
                        val documentFile = DocumentFile.fromSingleUri(context, fileUri)
                        if (documentFile != null && documentFile.exists()) {
                            val deleted = documentFile.delete()
                            result.success(deleted)
                        } else {
                            result.success(false) // File not found, but not an error
                        }
                    } catch (e: Exception) {
                        result.error("DELETE_FAILED", "Failed to delete file: ${e.message}", null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Folder channel for opening folders
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FOLDER_CHANNEL).setMethodCallHandler {
            call, result ->
            when (call.method) {
                "openFolder" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("ARGUMENT_ERROR", "Path is required.", null)
                        return@setMethodCallHandler
                    }

                    try {
                        // SAF URIの場合
                        if (path.startsWith("content://")) {
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(Uri.parse(path), "resource/folder")
                                flags = Intent.FLAG_GRANT_READ_URI_PERMISSION
                            }
                            // フォルダを開けるアプリがあるか確認
                            if (intent.resolveActivity(packageManager) != null) {
                                startActivity(intent)
                            } else {
                                // フォールバック: ファイルマネージャーを開く
                                val fallbackIntent = Intent(Intent.ACTION_VIEW).apply {
                                    data = Uri.parse(path)
                                    flags = Intent.FLAG_GRANT_READ_URI_PERMISSION
                                }
                                startActivity(Intent.createChooser(fallbackIntent, "Open with"))
                            }
                        } else {
                            // 通常のファイルパスの場合
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(Uri.parse("file://$path"), "resource/folder")
                            }
                            if (intent.resolveActivity(packageManager) != null) {
                                startActivity(intent)
                            } else {
                                // フォールバック: 一般的なファイルマネージャーを起動
                                val fallbackIntent = Intent(Intent.ACTION_GET_CONTENT).apply {
                                    type = "*/*"
                                }
                                startActivity(Intent.createChooser(fallbackIntent, "Open folder"))
                            }
                        }
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("OPEN_FAILED", "Failed to open folder: ${e.message}", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }


    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_CODE_OPEN_DOCUMENT_TREE && resultCode == Activity.RESULT_OK) {
            data?.data?.also { uri ->
                contentResolver.takePersistableUriPermission(uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)

                val prefs: SharedPreferences = getSharedPreferences("app_prefs", Context.MODE_PRIVATE)
                with (prefs.edit()) {
                    putString("saf_directory_uri", uri.toString())
                    apply()
                }
                pendingResult?.success(uri.toString())
            } ?: pendingResult?.error("CANCELLED", "SAF Directory selection cancelled.", null)
        } else if (requestCode == REQUEST_CODE_OPEN_DOCUMENT_TREE && resultCode == Activity.RESULT_CANCELED) {
             pendingResult?.error("CANCELLED", "SAF Directory selection cancelled.", null)
        }
        pendingResult = null // 結果を送信したらクリア
    }
}
