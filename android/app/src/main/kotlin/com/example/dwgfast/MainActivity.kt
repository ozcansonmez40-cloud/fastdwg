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

    // When a parse wedges inside native code (seen on 32-bit devices under
    // memory pressure), the single-thread queue is jammed forever: every later
    // open waits behind it until the process dies, which users "fix" by
    // rebooting the phone. Track when the running parse started so new
    // requests can detect the jam and offer an in-app restart instead.
    @Volatile private var activeParseStartMs = 0L

    companion object {
        /// A parse still running after this long is treated as wedged when the
        /// user tries to open ANOTHER drawing (legit big files finish sooner,
        /// and the check only fires on a second open attempt).
        private const val PARSE_STUCK_MS = 180_000L
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            rendererChannel
        )
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialDrawing" -> result.success(currentDrawingIntentPayload())
                "shareDrawing" -> {
                    val path = call.argument<String>("path")
                    val name = call.argument<String>("name")
                    if (path.isNullOrBlank() || name.isNullOrBlank()) {
                        result.error("FASTDWG_SHARE", "path/name missing", null)
                        return@setMethodCallHandler
                    }
                    // Copy off the main thread (drawings can be 50MB+), then
                    // hand the chooser a plain octet-stream so messaging apps
                    // store a type they are willing to re-open.
                    parseExecutor.execute {
                        try {
                            val shareDir = File(cacheDir, "fastdwg_share").apply { mkdirs() }
                            shareDir.listFiles()?.forEach { it.delete() }
                            // WhatsApp decides open-ability from the LAST file
                            // extension it sees: ".dwg" is unknown → "can't be
                            // opened", ".bin" is known → tap opens a chooser.
                            // So the outgoing copy is named "<name>.dwg.bin";
                            // the receiving side (below) strips the ".bin".
                            val wrappedName =
                                if (name.lowercase().endsWith(".dwg") ||
                                    name.lowercase().endsWith(".dxf")
                                ) "$name.bin" else name
                            val dest = File(shareDir, wrappedName)
                            File(path).inputStream().use { input ->
                                dest.outputStream().use { output -> input.copyTo(output) }
                            }
                            val uri = androidx.core.content.FileProvider.getUriForFile(
                                this, "$packageName.shareprovider", dest
                            )
                            val send = Intent(Intent.ACTION_SEND).apply {
                                type = "application/octet-stream"
                                putExtra(Intent.EXTRA_STREAM, uri)
                                clipData = android.content.ClipData.newUri(
                                    contentResolver, wrappedName, uri
                                )
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            Handler(Looper.getMainLooper()).post {
                                startActivity(Intent.createChooser(send, wrappedName))
                                result.success(true)
                            }
                        } catch (e: Exception) {
                            Handler(Looper.getMainLooper()).post {
                                result.error("FASTDWG_SHARE", e.message, null)
                            }
                        }
                    }
                }
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

                    val runningSince = activeParseStartMs
                    if (runningSince != 0L &&
                        System.currentTimeMillis() - runningSince > PARSE_STUCK_MS
                    ) {
                        // The queue is jammed behind a wedged parse — queueing
                        // this request would hang it too. Tell Flutter so it
                        // can offer a one-tap app restart.
                        result.success(mapOf(
                            "status" to "stuck",
                            "message" to "A previous drawing is stuck opening."
                        ))
                        return@setMethodCallHandler
                    }

                    val probe = nativeBridge.probe()
                    // Serialised on a single thread so parses never overlap.
                    parseExecutor.execute {
                        activeParseStartMs = System.currentTimeMillis()
                        try {
                            val parseResult = nativeBridge.prepareDrawing(uri, name ?: "drawing.dwg")
                            Handler(Looper.getMainLooper()).post {
                                result.success(parseResult + ("nativeProbe" to probe))
                            }
                        } finally {
                            activeParseStartMs = 0L
                        }
                    }
                }
                "restartApp" -> {
                    // Killing the process is the ONLY way to clear a native
                    // parse thread wedged inside LibreDWG (it can't be
                    // interrupted safely). Schedule a relaunch, then exit.
                    val launch = packageManager.getLaunchIntentForPackage(packageName)
                    if (launch != null) {
                        launch.addFlags(
                            Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
                        )
                        val pi = android.app.PendingIntent.getActivity(
                            this, 7391, launch,
                            android.app.PendingIntent.FLAG_CANCEL_CURRENT or
                                android.app.PendingIntent.FLAG_IMMUTABLE
                        )
                        val am = getSystemService(ALARM_SERVICE) as android.app.AlarmManager
                        am.set(
                            android.app.AlarmManager.RTC,
                            System.currentTimeMillis() + 400,
                            pi
                        )
                    }
                    result.success(true)
                    Handler(Looper.getMainLooper()).postDelayed({
                        finishAffinity()
                        Runtime.getRuntime().exit(0)
                    }, 250)
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
        val rawMetadata = readUriMetadata(data)
        // Drawings shared from FastDWG travel as "<name>.dwg.bin" so WhatsApp
        // agrees to open them (see shareDrawing); unwrap that suffix here so
        // the drawing keeps its real name and extension.
        val unwrappedName = rawMetadata.name.let {
            val lower = it.lowercase()
            if (lower.endsWith(".bin") &&
                (lower.removeSuffix(".bin").endsWith(".dwg") ||
                    lower.removeSuffix(".bin").endsWith(".dxf"))
            ) it.dropLast(4) else it
        }
        val metadata = rawMetadata.copy(name = unwrappedName)
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
