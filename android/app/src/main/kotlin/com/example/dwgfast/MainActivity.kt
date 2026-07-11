package com.example.dwgfast

import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val rendererChannel = "fastdwg/dwg_renderer"
    private val nativeBridge by lazy { NativeDwgBridge(this) }
    private var methodChannel: MethodChannel? = null

    // The native DWG parser shares global state and is heavy on memory, so it is
    // NOT safe to run two parses at once. Opening files rapidly (open → back →
    // open) used to spawn overlapping parse threads that raced on that global
    // state and crashed the process (SIGSEGV in dwg_decode). A single-thread
    // executor serialises every parse, so a new open simply queues behind the
    // previous one instead of colliding.
    private val parseExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            rendererChannel
        )
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialDrawing" -> result.success(currentDrawingIntentPayload())
                "prepareDrawing" -> {
                    val uri = call.argument<String>("uri")
                    val name = call.argument<String>("name")

                    if (uri.isNullOrBlank()) {
                        result.error(
                            "FASTDWG_MISSING_URI",
                            "DWG file URI is missing.",
                            null
                        )
                        return@setMethodCallHandler
                    }

                    val probe = nativeBridge.probe()
                    // Serialised on a single thread so parses never overlap.
                    parseExecutor.execute {
                        val parseResult = nativeBridge.prepareDrawing(uri, name ?: "drawing.dwg")
                        Handler(Looper.getMainLooper()).post {
                            result.success(parseResult + ("nativeProbe" to probe))
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        methodChannel?.invokeMethod("drawingIntentReceived", currentDrawingIntentPayload())
    }

    private fun currentDrawingIntentPayload(): Map<String, Any?>? {
        val currentIntent = intent ?: return null
        if (currentIntent.action != Intent.ACTION_VIEW &&
            currentIntent.action != Intent.ACTION_SEND &&
            currentIntent.action != Intent.ACTION_SEND_MULTIPLE) {
            return null
        }

        val extraStream: Uri? =
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                currentIntent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                currentIntent.getParcelableExtra(Intent.EXTRA_STREAM)
            }

        val firstMultipleStream: Uri? =
            if (currentIntent.action == Intent.ACTION_SEND_MULTIPLE) {
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                    currentIntent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                        ?.firstOrNull()
                } else {
                    @Suppress("DEPRECATION")
                    currentIntent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                        ?.firstOrNull()
                }
            } else {
                null
            }

        val data = currentIntent.data
            ?: extraStream
            ?: firstMultipleStream
            ?: currentIntent.clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.uri
            ?: return null
        val metadata = readUriMetadata(data)
        val ext = metadata.name.substringAfterLast('.', "dwg").lowercase()
        val persistentPath = copyIntentUriToCache(data, metadata.name) ?: return mapOf(
            "uri" to "",
            "sourceUri" to data.toString(),
            "name" to metadata.name,
            "fileExtension" to ext,
            "fileSizeBytes" to metadata.sizeBytes,
            "error" to "This provider did not grant readable access to the DWG file."
        )

        return mapOf(
            "uri" to persistentPath,
            "sourceUri" to data.toString(),
            "name" to metadata.name,
            "fileExtension" to ext,
            "fileSizeBytes" to metadata.sizeBytes
        )
    }

    private fun readUriMetadata(uri: android.net.Uri): DrawingIntentMetadata {
        var displayName: String? = null
        var sizeBytes: Long? = null

        if (uri.scheme == "content") {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)

                    if (nameIndex >= 0) {
                        displayName = cursor.getString(nameIndex)
                    }
                    if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                        sizeBytes = cursor.getLong(sizeIndex)
                    }
                }
            }
        }

        val fallbackName = uri.lastPathSegment
            ?.substringAfterLast('/')
            ?.substringAfterLast(':')
            ?.takeIf { it.isNotBlank() }
            ?: "drawing.dwg"

        return DrawingIntentMetadata(
            name = displayName?.takeIf { it.isNotBlank() } ?: fallbackName,
            sizeBytes = sizeBytes
        )
    }

    private fun copyIntentUriToCache(uri: Uri, name: String): String? {
        val safeName = name.replace(Regex("[^A-Za-z0-9._-]"), "_")
        val outputFile = File(cacheDir, "incoming_$safeName")

        return try {
            contentResolver.openInputStream(uri).use { input ->
                requireNotNull(input) { "Unable to open incoming DWG stream." }
                outputFile.outputStream().use { output -> input.copyTo(output) }
            }
            outputFile.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    private data class DrawingIntentMetadata(
        val name: String,
        val sizeBytes: Long?
    )

}
