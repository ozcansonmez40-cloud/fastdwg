package com.example.dwgfast

import android.content.Context
import android.net.Uri
import java.io.File

class NativeDwgBridge(private val context: Context) {
    init {
        System.loadLibrary("fastdwg_native")
    }

    fun probe(): String = nativeProbe()

    fun prepareDrawing(uri: String, name: String): Map<String, Any?> {
        val localFile = try {
            copyUriToCache(uri, name)
        } catch (error: Exception) {
            return mapOf(
                "status" to "unsupported",
                "message" to "$name could not be opened from this provider. Save the DWG to Downloads and open it from there.",
                "localPath" to null,
                "sceneJson" to "",
                "layers" to emptyList<String>(),
                "entityCount" to 0
            )
        }
        // The native side writes the packed scene directly to a file so the
        // multi-MB payload never crosses the platform channel (OOM-safe).
        // One scene file PER DRAWING (keyed by the input copy's path) so a
        // queued parse of the next file can never overwrite a scene the
        // previous screen is still reading. The app version is part of the
        // name so a build with parser fixes never serves scenes rendered by
        // an older parser.
        val sceneKey = Integer.toHexString(localFile.absolutePath.hashCode())
        val sceneFile =
            File(context.filesDir, "scene_${sceneKey}_v${BuildConfig.VERSION_CODE}.bin")
        // Fast path: an up-to-date scene from a previous open of the SAME
        // unchanged DWG is served as-is — seconds instead of a full re-parse.
        val cacheValid = sceneFile.length() >= 8 &&
            sceneFile.lastModified() >= localFile.lastModified() &&
            readErrFlag(sceneFile) == 0
        // Guard the native call: any Java-level failure (link error, etc.) is
        // turned into a clean "unsupported" result instead of crashing.
        val wrote = if (cacheValid) true else try {
            nativePrepareDrawing(localFile.absolutePath, name, sceneFile.absolutePath)
        } catch (error: Throwable) {
            false
        }

        // Scenes are tens of MB, so per-drawing naming must not grow storage
        // unbounded: keep only the newest few and drop the rest (plus the
        // legacy shared last_scene.bin). A reader that already opened a
        // deleted file keeps reading it fine (POSIX unlink semantics).
        if (wrote) {
            File(context.filesDir, "last_scene.bin").delete()
            context.filesDir
                .listFiles { f ->
                    f.name.startsWith("scene_") && f.name.endsWith(".bin") &&
                        f.name != sceneFile.name
                }
                ?.sortedByDescending { it.lastModified() }
                ?.drop(2)
                ?.forEach { it.delete() }
        }

        // Binary header: u32 magic, u32 errorFlag (little-endian). errorFlag == 0
        // means the parser produced a scene.
        val hasScene = wrote && sceneFile.length() >= 8 && readErrFlag(sceneFile) == 0

        return mapOf(
            "status" to if (hasScene) "ready" else "unsupported",
            "message" to if (hasScene) {
                "$name decoded by the native DWG parser."
            } else {
                "$name could not be decoded. The DWG version may be unsupported or the file may be corrupted."
            },
            "localPath" to localFile.absolutePath,
            "scenePath" to if (wrote) sceneFile.absolutePath else "",
            "layers" to emptyList<String>(),
            "entityCount" to 0
        )
    }

    /// The u32 error flag at offset 4 of a packed scene file; -1 if unreadable.
    private fun readErrFlag(f: File): Int {
        return try {
            val head = ByteArray(8)
            f.inputStream().use { it.read(head) }
            (head[4].toInt() and 0xFF) or
                ((head[5].toInt() and 0xFF) shl 8) or
                ((head[6].toInt() and 0xFF) shl 16) or
                ((head[7].toInt() and 0xFF) shl 24)
        } catch (_: Exception) {
            -1
        }
    }

    private fun copyUriToCache(uriValue: String, name: String): File {
        val safeName = name.replace(Regex("[^A-Za-z0-9._-]"), "_")
        val permanent = File(context.filesDir, "fastdwg_input_$safeName")

        // If already in the app's permanent storage, use it directly.
        if (uriValue.startsWith(context.filesDir.absolutePath) ||
            uriValue.startsWith(context.cacheDir.absolutePath)) {
            val source = File(uriValue)
            if (source.exists()) return source
        }

        // If a permanent copy already exists from a previous session, use it.
        if (permanent.exists() && permanent.length() > 0) {
            return permanent
        }

        if (uriValue.startsWith("content://")) {
            val uri = Uri.parse(uriValue)
            context.contentResolver.openInputStream(uri).use { input ->
                requireNotNull(input) { "Unable to open DWG content stream." }
                permanent.outputStream().use { output -> input.copyTo(output) }
            }
            return permanent
        }

        if (uriValue.startsWith("file://")) {
            File(Uri.parse(uriValue).path ?: uriValue).copyTo(permanent, overwrite = true)
            return permanent
        }

        val source = File(uriValue)
        if (source.exists()) {
            source.copyTo(permanent, overwrite = true)
            return permanent
        }

        error("DWG file could not be resolved from picker URI.")
    }

    private external fun nativeProbe(): String

    private external fun nativePrepareDrawing(
        filePath: String,
        name: String,
        outPath: String
    ): Boolean
}
