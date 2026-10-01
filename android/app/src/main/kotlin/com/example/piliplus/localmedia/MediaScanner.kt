package com.example.piliplus.localmedia

import android.content.ContentUris
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import java.io.File

/**
 * Local video library backed by MediaStore.
 *
 * Why MediaStore (documented deviation): libmedialibrary needs raw path
 * access, which on Android 11+ means the MANAGE_EXTERNAL_STORAGE ("all
 * files") permission. MediaStore delivers the same user-visible behavior
 * (indexed volumes incl. SD cards, folder grouping, incremental updates,
 * app-data directories and .nomedia excluded) with only the standard
 * READ_MEDIA_VIDEO / READ_EXTERNAL_STORAGE permissions, and it removes the
 * historical "media library init failure" class of problems entirely.
 *
 * Scans stream results back in batches ("scan while it goes") and never
 * block the main thread.
 */
class MediaScanner(private val context: Context) {

    data class Video(
        val id: Long,
        val name: String,
        val path: String,
        val uri: String,
        val durationMs: Long,
        val sizeBytes: Long,
        val dateAddedMs: Long,
        val bucketId: Long,
        val bucketName: String,
        val volume: String,
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "id" to id,
            "name" to name,
            "path" to path,
            "uri" to uri,
            "durationMs" to durationMs,
            "sizeBytes" to sizeBytes,
            "dateAddedMs" to dateAddedMs,
            "bucketId" to bucketId,
            "bucketName" to bucketName,
            "volume" to volume,
        )
    }

    private val lock = Any()
    private var knownIds: HashSet<Long>? = null
    private var lastDateAdded: Long = 0

    private fun volumes(): List<String> {
        val result = ArrayList<String>()
        result.add(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                for (v in MediaStore.getExternalVolumeNames(context)) {
                    if (v != MediaStore.VOLUME_EXTERNAL_PRIMARY && !result.contains(v)) result.add(v)
                }
            } catch (t: Throwable) {
                LogCollector.w("MediaScanner", "volume enumeration failed: $t")
            }
        } else {
            // Legacy: a single external content URI covers primary + SD.
            return listOf("__legacy__")
        }
        return result
    }

    private fun contentUri(volume: String): Uri =
        if (volume == "__legacy__") MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        else MediaStore.Video.Media.getContentUri(volume)

    private fun columns(): Array<String> {
        val cols = ArrayList(
            listOf(
                MediaStore.Video.Media._ID,
                MediaStore.Video.Media.DISPLAY_NAME,
                MediaStore.Video.Media.DATA,
                MediaStore.Video.Media.DURATION,
                MediaStore.Video.Media.SIZE,
                MediaStore.Video.Media.DATE_ADDED,
                MediaStore.Video.Media.BUCKET_ID,
                MediaStore.Video.Media.BUCKET_DISPLAY_NAME,
            )
        )
        return cols.toTypedArray()
    }

    /** True for paths that must never enter the index (app data dirs). */
    private fun excluded(path: String): Boolean {
        if (path.isEmpty()) return true
        val lower = path.lowercase()
        if (lower.contains("/android/data/") || lower.contains("/android/obb/")) return true
        if (lower.contains("/android/media/")) return true
        if (lower.startsWith("/data/")) return true
        // hidden dirs
        for (seg in path.split('/')) {
            if (seg.length > 1 && seg.startsWith(".")) return true
        }
        return false
    }

    private fun readRow(c: Cursor, volume: String): Video? {
        val id = c.getLong(0)
        val name = c.getString(1) ?: return null
        val path = c.getString(2) ?: ""
        if (excluded(path)) return null
        val duration = c.getLong(3)
        val size = c.getLong(4)
        val dateAdded = c.getLong(5) * 1000L
        val bucketId = c.getLong(6)
        val bucketName = c.getString(7) ?: File(path).parentFile?.name ?: "Unknown"
        val uri = ContentUris.withAppendedId(contentUri(volume), id).toString()
        return Video(id, name, path, uri, duration, size, dateAdded, bucketId, bucketName, volume)
    }

    /**
     * Full scan. Emits batches through [onBatch]; finishes with [onDone]
     * (total count). Runs on the caller's (background) thread.
     */
    fun fullScan(
        onBatch: (List<Map<String, Any?>>, Int) -> Unit,
        onProgress: (Int) -> Unit,
        onDone: (Int) -> Unit,
        onError: (String) -> Unit,
    ) {
        try {
            val ids = HashSet<Long>()
            var total = 0
            var maxDate = 0L
            for (volume in volumes()) {
                val base = contentUri(volume)
                context.contentResolver.query(
                    base, columns(), null, null,
                    "${MediaStore.Video.Media.DATE_ADDED} ASC"
                )?.use { c ->
                    val batch = ArrayList<Map<String, Any?>>(200)
                    while (c.moveToNext()) {
                        val v = readRow(c, volume) ?: continue
                        ids.add(v.id)
                        total++
                        if (v.dateAddedMs > maxDate) maxDate = v.dateAddedMs
                        batch.add(v.toMap())
                        if (batch.size >= 200) {
                            onBatch(batch.toList(), total)
                            onProgress(total)
                            batch.clear()
                        }
                    }
                    if (batch.isNotEmpty()) {
                        onBatch(batch.toList(), total)
                        onProgress(total)
                    }
                }
            }
            synchronized(lock) {
                knownIds = ids
                lastDateAdded = maxDate
            }
            onDone(total)
        } catch (t: Throwable) {
            LogCollector.e("MediaScanner", "fullScan failed", t)
            onError(t.toString())
        }
    }

    /**
     * Incremental refresh: picks up items added since the last scan and
     * reports ids that disappeared. Cheap enough to run on every page
     * entry and on MediaStore observer notifications.
     */
    fun deltaScan(
        onAdded: (List<Map<String, Any?>>) -> Unit,
        onRemoved: (List<Long>) -> Unit,
        onError: (String) -> Unit,
    ) {
        try {
            val since: Long
            val previous: HashSet<Long>?
            synchronized(lock) {
                since = lastDateAdded
                previous = knownIds
            }
            if (previous == null) {
                onError("no_base_scan")
                return
            }
            val current = HashSet<Long>(previous.size)
            val added = ArrayList<Map<String, Any?>>()
            var maxDate = since
            for (volume in volumes()) {
                context.contentResolver.query(
                    contentUri(volume), columns(), null, null,
                    "${MediaStore.Video.Media.DATE_ADDED} ASC"
                )?.use { c ->
                    while (c.moveToNext()) {
                        val v = readRow(c, volume) ?: continue
                        current.add(v.id)
                        if (v.dateAddedMs > maxDate) maxDate = v.dateAddedMs
                        if (!previous.contains(v.id)) added.add(v.toMap())
                    }
                }
            }
            val removed = (previous - current).toList()
            synchronized(lock) {
                knownIds = current
                lastDateAdded = maxDate
            }
            if (added.isNotEmpty()) onAdded(added)
            if (removed.isNotEmpty()) onRemoved(removed)
        } catch (t: Throwable) {
            LogCollector.e("MediaScanner", "deltaScan failed", t)
            onError(t.toString())
        }
    }

    /** Name search, optionally restricted to a folder; hard-capped. */
    fun search(query: String, bucketId: Long?, limit: Int): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        if (query.isBlank()) return out
        try {
            val cap = limit.coerceIn(1, 500)
            for (volume in volumes()) {
                val sel = StringBuilder("${MediaStore.Video.Media.DISPLAY_NAME} LIKE ?")
                val args = ArrayList<String>()
                args.add("%$query%")
                if (bucketId != null) {
                    sel.append(" AND ${MediaStore.Video.Media.BUCKET_ID} = ?")
                    args.add(bucketId.toString())
                }
                context.contentResolver.query(
                    contentUri(volume), columns(), sel.toString(), args.toTypedArray(),
                    "${MediaStore.Video.Media.DISPLAY_NAME} ASC"
                )?.use { c ->
                    while (c.moveToNext() && out.size < cap) {
                        readRow(c, volume)?.let { out.add(it.toMap()) }
                    }
                }
                if (out.size >= cap) break
            }
        } catch (t: Throwable) {
            LogCollector.e("MediaScanner", "search failed", t)
        }
        return out
    }
}
