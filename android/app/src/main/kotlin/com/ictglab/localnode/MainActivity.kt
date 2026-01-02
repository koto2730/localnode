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
