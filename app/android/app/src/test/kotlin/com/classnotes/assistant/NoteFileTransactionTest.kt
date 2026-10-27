package com.classnotes.assistant

import org.junit.Assert.*
import org.junit.Test

class NoteFileTransactionTest {
    class Store : NoteDocuments {
        data class Entry(var name: String, var bytes: ByteArray)
        val files = mutableMapOf<String, Entry>()
        var serial = 0
        var log: NoteSwap? = null
        var failNewRename = false
        var editOnStage = false
        var failDelete = false
        override fun find(parent: String, name: String) = files.entries.firstOrNull { it.value.name == name }?.key
        override fun create(parent: String, name: String): String {
            val id = (++serial).toString(); files[id] = Entry(name, byteArrayOf()); return id
        }
        override fun read(id: String) = files.getValue(id).bytes
        override fun write(id: String, bytes: ByteArray) {
            files.getValue(id).bytes = bytes
            if (editOnStage) files.values.first { it.name == "课程.md" }.bytes = "phone edit".toByteArray()
        }
        override fun rename(id: String, name: String): String {
            if (failNewRename && files.getValue(id).name.startsWith(".cna-sync-stage")) throw IllegalStateException("provider refused rename")
            // A real SAF provider can change document IDs when renaming.
            val entry = files.remove(id)!!; entry.name = name
            val next = (++serial).toString(); files[next] = entry; return next
        }
        override fun journal(value: NoteSwap?) { log = value }
        override fun delete(id: String) { if (failDelete) error("delete denied"); files.remove(id) }
        override fun pending() = log
    }
    private val old = "原文\r\n公式 \$u=1\$".toByteArray()
    private val new = "\uFEFF新版\r\n公式 \$\\sqrt{2}\$".toByteArray()
    private fun prepare(): Store = Store().apply { write(create("root", "课程.md"), old) }

    @Test fun update_retains_old_bytes_and_verifies_new_bytes() {
        val store = prepare(); val sync = NoteFileTransaction(store)
        val id = sync.install("root", "课程.md", new, NoteFileTransaction.hash(old), NoteFileTransaction.hash(new))
        assertArrayEquals(new, store.read(id))
        assertArrayEquals(old, store.read(store.find("root", sync.lastBackup!!)!!))
        assertNull(store.log)
    }
    @Test fun rejected_provider_rename_restores_original_even_if_ids_change() {
        val store = prepare(); store.failNewRename = true
        try { NoteFileTransaction(store).install("root", "课程.md", new, NoteFileTransaction.hash(old), NoteFileTransaction.hash(new)); fail() }
        catch (_: IllegalStateException) {}
        assertArrayEquals(old, store.read(store.find("root", "课程.md")!!)); assertNull(store.log)
    }
    @Test fun concurrent_edit_after_stage_is_never_overwritten() {
        val store = prepare(); store.editOnStage = true
        try { NoteFileTransaction(store).install("root", "课程.md", new, NoteFileTransaction.hash(old), NoteFileTransaction.hash(new)); fail() }
        catch (_: IllegalArgumentException) {}
        assertArrayEquals("phone edit".toByteArray(), store.read(store.find("root", "课程.md")!!))
        assertNull(store.log)
    }
    @Test fun corruption_and_unknown_hash_never_modify_original() {
        val store = prepare()
        for (base in listOf<String?>(null, "bad")) {
            try { NoteFileTransaction(store).install("root", "课程.md", new, base, NoteFileTransaction.hash(new)); fail() }
            catch (_: IllegalArgumentException) {}
        }
        try { NoteFileTransaction(store).install("root", "课程.md", new, NoteFileTransaction.hash(old), "bad"); fail() }
        catch (_: IllegalArgumentException) {}
        assertArrayEquals(old, store.read(store.find("root", "课程.md")!!))
    }
    @Test fun process_crash_between_renames_recovers_old_original() {
        val store = prepare(); val previous = store.find("root", "课程.md")!!
        val stage = store.create("root", ".cna-sync-stage-test.md"); store.write(stage, new)
        store.journal(NoteSwap("root", "课程.md", stage, ".cna-sync-old-test.md", NoteFileTransaction.hash(old), NoteFileTransaction.hash(new)))
        store.rename(previous, ".cna-sync-old-test.md")
        NoteFileTransaction(store).recover()
        assertArrayEquals(old, store.read(store.find("root", "课程.md")!!)); assertNull(store.log)
    }
    @Test fun process_crash_after_commit_keeps_new_original_and_old_backup() {
        val store = prepare(); val previous = store.find("root", "课程.md")!!
        val stage = store.create("root", ".cna-sync-stage-test.md"); store.write(stage, new)
        store.journal(NoteSwap("root", "课程.md", stage, ".cna-sync-old-test.md", NoteFileTransaction.hash(old), NoteFileTransaction.hash(new)))
        store.rename(previous, ".cna-sync-old-test.md"); store.rename(stage, "课程.md")
        NoteFileTransaction(store).recover()
        assertArrayEquals(new, store.read(store.find("root", "课程.md")!!))
        assertArrayEquals(old, store.read(store.find("root", ".cna-sync-old-test.md")!!)); assertNull(store.log)
    }
    @Test fun explicit_choice_discards_losing_bytes_and_all_transaction_files() {
        val store = prepare(); val sync = NoteFileTransaction(store)
        val id = sync.install("root", "课程.md", new, NoteFileTransaction.hash(old), NoteFileTransaction.hash(new), false)
        assertArrayEquals(new, store.read(id))
        assertEquals(listOf("课程.md"), store.files.values.map { it.name })
        assertNull(sync.lastBackup); assertNull(store.log)
    }
    @Test fun crash_after_no_backup_commit_finishes_cleanup_before_success() {
        val store = prepare(); val previous = store.find("root", "课程.md")!!
        val stageName = ".cna-sync-stage-test.md"
        val stage = store.create("root", stageName); store.write(stage, new)
        store.journal(NoteSwap("root", "课程.md", stage, ".cna-sync-old-test.md", NoteFileTransaction.hash(old), NoteFileTransaction.hash(new), false, stageName))
        store.rename(previous, ".cna-sync-old-test.md"); store.rename(stage, "课程.md")
        NoteFileTransaction(store).recover()
        assertEquals(listOf("课程.md"), store.files.values.map { it.name })
        assertArrayEquals(new, store.read(store.find("root", "课程.md")!!)); assertNull(store.log)
    }
    @Test fun crash_before_no_backup_commit_restores_original_and_cleans_stage() {
        val store = prepare(); val previous = store.find("root", "课程.md")!!
        val stageName = ".cna-sync-stage-test.md"
        val stage = store.create("root", stageName); store.write(stage, new)
        store.journal(NoteSwap("root", "课程.md", stage, ".cna-sync-old-test.md", NoteFileTransaction.hash(old), NoteFileTransaction.hash(new), false, stageName))
        store.rename(previous, ".cna-sync-old-test.md")
        NoteFileTransaction(store).recover()
        assertEquals(listOf("课程.md"), store.files.values.map { it.name })
        assertArrayEquals(old, store.read(store.find("root", "课程.md")!!)); assertNull(store.log)
    }
    @Test fun refused_cleanup_remains_pending_until_provider_allows_delete() {
        val store = prepare(); val sync = NoteFileTransaction(store); store.failDelete = true
        try { sync.install("root", "课程.md", new, NoteFileTransaction.hash(old), NoteFileTransaction.hash(new), false); fail() }
        catch (_: IllegalStateException) {}
        assertNotNull(store.log)
        assertArrayEquals(new, store.read(store.find("root", "课程.md")!!))
        assertEquals(2, store.files.size)
        store.failDelete = false; sync.recover()
        assertEquals(1, store.files.size); assertNull(store.log)
    }
}
