package audio

import android.content.Context
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

    private val audioDir: File
        get() {
            val dir = File(context.getExternalFilesDir(null), "recordings")
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

    fun deleteAudioFile(filePath: String): Boolean {
        val f = File(filePath)
        return if (f.exists()) f.delete() else false
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
