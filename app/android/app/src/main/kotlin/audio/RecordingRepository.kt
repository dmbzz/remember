package audio

import android.content.Context
import android.media.MediaMetadataRetriever
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 录音存储仓库与会话管理。
 * - 写入 App 私有目录（getExternalFilesDir），保障安全与合规。
 * - 提供崩溃恢复机制：若应用崩溃，下次启动扫描可能未落盘结束的录音分片。
 */
class RecordingRepository(private val context: Context) {
    fun durationMs(file: File): Long {
        val metadata = MediaMetadataRetriever()
        return try {
            metadata.setDataSource(file.absolutePath)
            metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()?.coerceAtLeast(0) ?: 0L
        } catch (_: Exception) { 0L }
        finally { try { metadata.release() } catch (_: Exception) {} }
    }

    private val audioDir: File
        get() {
            val external = context.getExternalFilesDir(null)
                ?: error("无法读取本机录音目录")
            val dir = File(external, "recordings")
            if (!dir.exists()) {
                dir.mkdirs()
            }
            return dir
        }

    fun createAudioFile(sessionId: String, codec: String): File {
        val ext = if (codec.lowercase() == "wav") "wav" else "m4a"
        val timestamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.getDefault()).format(Date())
        return File(audioDir, "rec_${sessionId}_$timestamp.$ext")
    }

    fun getAudioFile(filePath: String): File? {
        val f = File(filePath)
        return if (f.exists()) f else null
    }

    private fun savedAudioFile(filePath: String): File {
        require(filePath.isNotBlank()) { "录音路径不能为空" }
        val supplied = File(filePath)
        val root = audioDir.canonicalFile
        val file = supplied.canonicalFile
        // Only direct app-owned audio files are eligible. In particular, do not
        // follow a symlink out of recordings, or accept a directory traversal.
        require(supplied.isAbsolute &&
            supplied.absolutePath == File(audioDir, supplied.name).absolutePath &&
            file.parentFile == root && file.name == supplied.name &&
            file.extension.lowercase(Locale.ROOT) in setOf("m4a", "wav")) {
            "只能删除本应用录音目录中的音频"
        }
        require(!file.exists() || file.isFile) { "录音路径不是普通文件" }
        return file
    }

    private val discardPreferences
        get() = context.getSharedPreferences("class_notes_recording_discards", Context.MODE_PRIVATE)

    fun markDiscardRequested(filePath: String) {
        val file = savedAudioFile(filePath)
        val paths = discardPreferences.getStringSet("paths", emptySet())!!.toMutableSet()
        paths.add(file.path)
        check(discardPreferences.edit().putStringSet("paths", paths).commit()) {
            "无法保存删除请求，录音未停止"
        }
    }

    fun isDiscardRequested(file: File): Boolean =
        discardPreferences.getStringSet("paths", emptySet())!!.contains(file.canonicalPath)

    fun deleteAudioFile(filePath: String, activeFile: File? = null): Boolean {
        val file = savedAudioFile(filePath)
        check(activeFile?.canonicalFile != file) { "录音正在进行，请先停止录音" }
        check(!file.exists() || file.delete()) { "手机录音删除失败，请重试" }
        check(!file.exists()) { "手机录音删除失败，请重试" }
        val paths = discardPreferences.getStringSet("paths", emptySet())!!.toMutableSet()
        if (paths.remove(file.path)) {
            check(discardPreferences.edit().putStringSet("paths", paths).commit()) {
                "录音已删除，但删除请求尚未清理，请重试"
            }
        }
        return true
    }

    /**
     * 崩溃自检恢复：检查是否存在由于系统强杀产生的未完结录音片段
     */
    fun scanUnfinishedRecordings(): List<File> {
        val files = audioDir.listFiles { file ->
            file.isFile && (file.extension == "m4a" || file.extension == "wav")
        }
        return files?.toList() ?: emptyList()
    }
}
