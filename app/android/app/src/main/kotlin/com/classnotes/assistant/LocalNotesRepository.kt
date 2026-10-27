package com.classnotes.assistant

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import java.security.MessageDigest
import org.json.JSONObject

/** Read and synchronize only the user-selected classroom Markdown directory. */
class LocalNotesRepository(private val context: Context) {
    companion object { private val lock = Any() }
    private val prefs = context.getSharedPreferences("class_notes_local_notes", Context.MODE_PRIVATE)

    fun saveFolder(uri: Uri, flags: Int): String = synchronized(lock) {
        context.contentResolver.takePersistableUriPermission(uri,
            flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION))
        val root = DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
        val name = info(root)?.second ?: "Obsidian 文件夹"
        prefs.edit().putString("tree", uri.toString()).putString("label", name).apply()
        name
    }

    fun folderLabel(): String? = if (prefs.getString("tree", null) == null) null else prefs.getString("label", null)
    fun folderInfo(): Map<String, Any>? = prefs.getString("tree", null)?.let {
        mapOf("label" to (folderLabel() ?: "Obsidian 文件夹"), "identity" to it, "writable" to context.contentResolver.persistedUriPermissions.any { permission -> permission.uri.toString() == it && permission.isReadPermission && permission.isWritePermission })
    }

    fun identityHash(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private fun tree(): Uri = Uri.parse(prefs.getString("tree", null) ?: error("请先选择手机上的 Obsidian 笔记文件夹"))
    private fun canonical(uri: Uri): String = DocumentsContract.buildDocumentUriUsingTree(tree(), DocumentsContract.getDocumentId(uri)).toString()

    private fun info(uri: Uri): Triple<String, String, String>? =
        context.contentResolver.query(uri, arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE), null, null, null)?.use { cursor ->
            if (!cursor.moveToFirst()) null else Triple(cursor.getString(0), cursor.getString(1), cursor.getString(2))
        }

    private fun children(tree: Uri, parent: Uri): List<Triple<Uri, String, String>> {
        val childUri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getDocumentId(parent))
        val list = mutableListOf<Triple<Uri, String, String>>()
        context.contentResolver.query(childUri, arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE), null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                list.add(Triple(DocumentsContract.buildDocumentUriUsingTree(tree, cursor.getString(0)),
                    cursor.getString(1), cursor.getString(2)))
            }
        } ?: error("手机已撤销文件夹读取授权，请重新选择")
        return list
    }

    fun list(): Map<String, Any> = synchronized(lock) {
        val tree = tree()
        transaction.recover()
        val notesRoot = notesRoot(tree, false)
            ?: return@synchronized mapOf("folder" to (folderLabel() ?: "笔记文件夹"), "items" to emptyList<Map<String, Any>>())
        val result = mutableListOf<Map<String, Any?>>()
        fun visit(parent: Uri, prefix: String, depth: Int) {
            require(depth <= 16 && result.size <= 5000) { "笔记目录层级或文件数量过大" }
            for ((uri, name, mime) in children(tree, parent)) {
                if (name.startsWith(".") || name.startsWith("00-")) continue
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                    if (name != "转写原文") visit(uri, if (prefix.isEmpty()) name else "$prefix/$name", depth + 1)
                    continue
                }
                if (!name.endsWith(".md", ignoreCase = true)) continue
                val relative = if (prefix.isEmpty()) name else "$prefix/$name"
                val digest = MessageDigest.getInstance("SHA-256")
                context.contentResolver.openInputStream(uri)?.use { stream ->
                    val buffer = ByteArray(65536)
                    while (true) {
                        val read = stream.read(buffer)
                        if (read < 0) break
                        digest.update(buffer, 0, read)
                    }
                } ?: error("无法读取笔记：$relative")
                val stem = name.dropLast(3)
                val dateMatch = Regex("_(\\d{4}-\\d{2}-\\d{2})$").find(stem)
                result.add(mapOf(
                    "note_id" to "local:$uri",
                    "topic" to (dateMatch?.let { stem.substring(0, it.range.first) } ?: stem),
                    "course_name" to (prefix.substringAfterLast('/').ifEmpty { "未分类" }),
                    "class_date" to dateMatch?.groupValues?.get(1),
                    "relative_path" to relative,
                    "sha256" to digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
                ))
            }
        }
        visit(notesRoot, "", 0)
        result.sortBy { it["relative_path"].toString() }
        mapOf("folder" to (folderLabel() ?: "Obsidian 文件夹"), "items" to result)
    }

    private fun notesRoot(tree: Uri, create: Boolean): Uri? {
        val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val rootName = info(root)?.second ?: error("手机已撤销目录授权，请重新选择目录")
        if (rootName == "课堂笔记") return root
        val existing = children(tree, root).filter { it.second == "课堂笔记" }
        require(existing.size <= 1) { "目录包含重名的课堂笔记文件夹" }
        existing.firstOrNull()?.let {
            require(it.third == DocumentsContract.Document.MIME_TYPE_DIR)
            return it.first
        }
        if (!create) return null
        return DocumentsContract.createDocument(context.contentResolver, root, DocumentsContract.Document.MIME_TYPE_DIR, "课堂笔记")
            ?: error("无法创建课堂笔记目录，请重新授予读写权限")
    }

    private fun bytes(uri: Uri): ByteArray = context.contentResolver.openInputStream(uri)?.use { stream ->
        val output = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(65536)
        while (true) {
            val count = stream.read(buffer)
            if (count < 0) break
            require(output.size() + count <= 10 * 1024 * 1024) { "笔记超过10 MB" }
            output.write(buffer, 0, count)
        }
        output.toByteArray()
    } ?: error("无法读取手机笔记")

    private val documents = object : NoteDocuments {
        override fun find(parent: String, name: String): String? {
            val matches = children(tree(), Uri.parse(parent)).filter { it.second.equals(name, true) }
            require(matches.size <= 1 && matches.all { it.second == name }) { "手机目录有重名或大小写不同的笔记，已停止覆盖" }
            return matches.firstOrNull()?.first?.toString()
        }
        override fun create(parent: String, name: String): String {
            require(find(parent, name) == null)
            val uri = DocumentsContract.createDocument(context.contentResolver, Uri.parse(parent), "text/markdown", name)
                ?: error("无法创建笔记文件")
            require(info(uri)?.second == name) { "该文件提供方改变了文件名，无法安全同步" }
            return canonical(uri)
        }
        override fun read(id: String) = bytes(Uri.parse(id))
        override fun write(id: String, bytes: ByteArray) {
            context.contentResolver.openOutputStream(Uri.parse(id), "wt")?.use { it.write(bytes); it.flush() }
                ?: error("无法写入笔记，请重新授予目录读写权限")
        }
        override fun rename(id: String, name: String): String {
            val uri = DocumentsContract.renameDocument(context.contentResolver, Uri.parse(id), name)
                ?: error("该目录不支持安全改名，请选择手机本地目录")
            require(info(uri)?.second == name) { "改名结果异常，旧版本仍保留" }
            return canonical(uri)
        }
        override fun delete(id: String) {
            check(DocumentsContract.deleteDocument(context.contentResolver, Uri.parse(id))) { "新版已保存，但旧文件清理失败；请重试同步完成清理" }
        }
        override fun journal(value: NoteSwap?) {
            val editor = prefs.edit()
            if (value == null) editor.remove("sync_swap_" + identityHash(tree().toString())) else editor.putString("sync_swap_" + identityHash(tree().toString()), JSONObject(mapOf(
                "tree" to tree().toString(), "parent" to value.parent, "name" to value.name,
                "stage" to value.stage, "backupName" to value.backupName,
                "oldHash" to value.oldHash, "newHash" to value.newHash,
                "keepBackup" to value.keepBackup, "stageName" to value.stageName)).toString())
            check(editor.commit()) { "无法保存同步恢复记录，已停止写入" }
        }
        override fun pending(): NoteSwap? {
            val json = prefs.getString("sync_swap_" + identityHash(tree().toString()), null)?.let { JSONObject(it) } ?: return null
            require(json.getString("tree") == tree().toString()) { "旧目录还有未恢复的同步，请先重新选择旧目录" }
            return NoteSwap(json.getString("parent"), json.getString("name"), json.getString("stage"),
                json.getString("backupName"), if (json.isNull("oldHash")) null else json.getString("oldHash"), json.getString("newHash"),
                json.optBoolean("keepBackup", true), if (json.isNull("stageName")) null else json.optString("stageName", null))
        }
    }
    private val transaction = NoteFileTransaction(documents)

    fun install(path: String, content: ByteArray, remoteHash: String, expectedHash: String?, identity: String, keepBackup: Boolean = true): Map<String, Any> = synchronized(lock) {
        val tree = tree()
        require(tree.toString() == identity) { "手机目录已切换，已停止旧同步" }
        require(folderInfo()?.get("writable") == true) { "请重新选择手机目录，授予笔记同步读写权限" }
        transaction.recover()
        val parts = path.split('/')
        require(path.length <= 1024 && parts.size <= 17 && path.endsWith(".md", true) && !path.contains('\\') &&
            !path.contains(':') && !path.contains('\u0000') && parts.none { it.isEmpty() || it == "." || it == ".." || it.startsWith(".") || it.startsWith("00-") || it == "转写原文" }) { "无效的同步笔记路径" }
        var parent = notesRoot(tree, true)!!
        for (part in parts.dropLast(1)) {
            val found = documents.find(parent.toString(), part)
            parent = if (found != null) {
                val uri = Uri.parse(found)
                require(info(uri)?.third == DocumentsContract.Document.MIME_TYPE_DIR)
                uri
            } else DocumentsContract.createDocument(context.contentResolver, parent, DocumentsContract.Document.MIME_TYPE_DIR, part)
                ?: error("无法创建课程目录")
        }
        val uri = transaction.install(parent.toString(), parts.last(), content, expectedHash, remoteHash, keepBackup)
        val result = mutableMapOf<String, Any>("note_id" to "local:$uri", "sha256" to remoteHash, "bytes" to content.size)
        transaction.lastBackup?.let { name ->
            result["backup_path"] = (parts.dropLast(1) + name).joinToString("/")
            documents.find(parent.toString(), name)?.let { result["backup_note_id"] = "local:$it" }
        }
        result
    }

    fun export(path: String, expectedHash: String, identity: String): Map<String, Any> = synchronized(lock) {
        val tree = tree()
        require(tree.toString() == identity) { "手机目录已变化，停止传输" }
        transaction.recover()
        val parts = path.split('/')
        require(path.length <= 1024 && parts.size <= 17 && path.endsWith(".md", true) &&
            !path.contains('\\') && !path.contains(':') && !path.contains('\u0000') &&
            parts.none { it.isEmpty() || it == "." || it == ".." || it.startsWith(".") || it.startsWith("00-") || it == "转写原文" }) { "无效的笔记路径" }
        var parent = notesRoot(tree, false) ?: error("手机课堂笔记目录不存在")
        for (part in parts) {
            parent = Uri.parse(documents.find(parent.toString(), part) ?: error("手机笔记已移动"))
        }
        val data = bytes(parent)
        require(NoteFileTransaction.hash(data) == expectedHash) { "手机笔记已变化，请重新核对后选择" }
        mapOf("sha256" to expectedHash, "bytes" to data.size, "content" to data)
    }

    fun read(noteId: String): String = synchronized(lock) {
        require(noteId.startsWith("local:")) { "不是本地笔记" }
        val currentTree = tree()
        transaction.recover()
        val uri = Uri.parse(noteId.removePrefix("local:"))
        require(uri.authority == currentTree.authority && DocumentsContract.getTreeDocumentId(uri) == DocumentsContract.getTreeDocumentId(currentTree)) { "笔记不属于当前所选目录" }
        String(bytes(uri), Charsets.UTF_8)
    }
}
