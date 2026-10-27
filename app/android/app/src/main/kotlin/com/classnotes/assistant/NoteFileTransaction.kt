package com.classnotes.assistant

import java.security.MessageDigest
import java.util.UUID

data class NoteSwap(val parent: String, val name: String, val stage: String,
    val backupName: String, val oldHash: String?, val newHash: String,
    val keepBackup: Boolean = true, val stageName: String? = null)

interface NoteDocuments {
    fun find(parent: String, name: String): String?
    fun create(parent: String, name: String): String
    fun read(id: String): ByteArray
    fun write(id: String, bytes: ByteArray)
    fun rename(id: String, name: String): String
    fun delete(id: String)
    fun journal(value: NoteSwap?)
    fun pending(): NoteSwap?
}

/** Stage, verify, retain old revision, swap. A crash is recovered before any scan. */
class NoteFileTransaction(private val files: NoteDocuments) {
    var lastBackup: String? = null
        private set
    companion object {
        fun hash(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
            .digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    fun recover() {
        val swap = files.pending() ?: return
        val target = files.find(swap.parent, swap.name)
        val targetHash = target?.let { hash(files.read(it)) }
        fun cleanStage() {
            swap.stageName?.let { name -> files.find(swap.parent, name)?.let { id ->
                require(hash(files.read(id)) == swap.newHash) { "临时笔记内容已变化，停止清理" }
                files.delete(id)
            } }
        }
        if (targetHash == swap.newHash) {
            if (!swap.keepBackup) files.find(swap.parent, swap.backupName)?.let { id ->
                require(hash(files.read(id)) == swap.oldHash) { "待清理旧文件已变化，停止清理" }
                files.delete(id)
            }
            cleanStage()
            files.journal(null)
            return
        }
        if (swap.oldHash != null && targetHash == swap.oldHash) {
            cleanStage()
            files.journal(null)
            return
        }
        val backup = files.find(swap.parent, swap.backupName)
        if (target == null && backup != null && hash(files.read(backup)) == swap.oldHash) {
            files.rename(backup, swap.name)
            check(hash(files.read(files.find(swap.parent, swap.name)!!)) == swap.oldHash)
            cleanStage()
            files.journal(null)
        } else if (target == null && swap.oldHash == null) {
            cleanStage()
            files.journal(null)
        } else {
            error("笔记更新中断，原文件备份仍保留；请重新选择目录并检查隐藏的 .cna-sync-old 文件")
        }
    }

    fun install(parent: String, name: String, bytes: ByteArray, expectedLocal: String?, remoteHash: String, keepBackup: Boolean = true): String {
        lastBackup = null
        require(bytes.size <= 10 * 1024 * 1024 && hash(bytes) == remoteHash) { "笔记传输不完整，原文件未修改" }
        recover()
        var previous = files.find(parent, name)
        val before = previous?.let { hash(files.read(it)) }
        require(before == expectedLocal) { "手机笔记在同步时发生变化，已停止覆盖" }
        if (before == remoteHash) return previous!!
        val tag = UUID.randomUUID().toString()
        val stageName = ".cna-sync-stage-$tag.md"
        val stage = files.create(parent, stageName)
        files.write(stage, bytes)
        require(hash(files.read(stage)) == remoteHash) { "手机存储校验失败，原文件未修改" }
        previous = files.find(parent, name)
        require(previous?.let { hash(files.read(it)) } == expectedLocal) { "手机笔记在同步时发生变化，已停止覆盖" }
        val swap = NoteSwap(parent, name, stage, ".cna-sync-old-$tag.md", before, remoteHash, keepBackup, stageName)
        files.journal(swap) // Durable before renaming the original.
        try {
            if (previous != null) files.rename(previous, swap.backupName)
            val result = files.rename(stage, name)
            require(files.find(parent, name) == result && hash(files.read(result)) == remoteHash)
            if (keepBackup) {
                files.journal(null)
                if (previous != null) lastBackup = swap.backupName
            } else recover() // Clear losing bytes before reporting successful sync.
            return result
        } catch (error: Exception) {
            recover()
            throw error
        }
    }
}
