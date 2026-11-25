package audio

import android.Manifest
import android.app.Application
import android.content.Context
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeNoException
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.android.controller.ServiceController
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28])
@LooperMode(LooperMode.Mode.PAUSED)
class RecordingDeletionTest {
    private lateinit var app: Application
    private lateinit var repository: RecordingRepository
    private var controller: ServiceController<AudioRecordService>? = null

    @Before fun setup() {
        app = RuntimeEnvironment.getApplication()
        repository = RecordingRepository(app)
        app.getSharedPreferences("class_notes_recording_discards", Context.MODE_PRIVATE)
            .edit().clear().commit()
        shadowOf(app).grantPermissions(Manifest.permission.RECORD_AUDIO)
        AudioRecordService.activeInstance = null
    }

    @After fun cleanup() {
        controller?.destroy()
        AudioRecordService.activeInstance = null
    }

    private fun audio(session: String = "test"): File =
        repository.createAudioFile(session, "aac").apply { writeText("fictional audio") }

    private fun service(): AudioRecordService {
        val created = Robolectric.buildService(AudioRecordService::class.java).create()
        controller = created
        return created.get()
    }

    private fun rejects(block: () -> Unit) {
        try { block(); fail("Expected recording protection to refuse the operation") }
        catch (_: IllegalArgumentException) { }
        catch (_: IllegalStateException) { }
    }

    @Test fun deleteOwnedSavedAudioIsIdempotent() {
        val file = audio()
        assertTrue(repository.deleteAudioFile(file.path))
        assertFalse(file.exists())
        assertTrue(repository.deleteAudioFile(file.path))
    }

    @Test fun cannotDeleteOutsideRecordingsOrTraverseOutOfRoot() {
        val ordinary = audio()
        val outside = File(app.getExternalFilesDir(null), "outside.m4a").apply { writeText("keep") }
        rejects { repository.deleteAudioFile(outside.path) }
        rejects { repository.deleteAudioFile(File(ordinary.parentFile, "../outside.m4a").path) }
        assertEquals("keep", outside.readText())
        assertTrue(ordinary.exists())
    }

    @Test fun cannotDeleteDirectoryOrNonAudioFile() {
        val ordinary = audio()
        val document = File(ordinary.parentFile, "notes.txt").apply { writeText("keep") }
        val directory = File(ordinary.parentFile, "folder.m4a").apply { mkdir() }
        rejects { repository.deleteAudioFile(document.path) }
        rejects { repository.deleteAudioFile(directory.path) }
        assertEquals("keep", document.readText())
        assertTrue(directory.isDirectory)
    }

    @Test fun cannotFollowAudioSymlinkOutsideRecordings() {
        val ordinary = audio()
        val outside = File(app.getExternalFilesDir(null), "symlink-target.m4a").apply { writeText("keep") }
        val link = File(ordinary.parentFile, "linked.m4a")
        try { Files.createSymbolicLink(link.toPath(), outside.toPath()) }
        catch (e: Exception) { assumeNoException("Host does not allow symbolic links", e); return }
        rejects { repository.deleteAudioFile(link.path) }
        assertEquals("keep", outside.readText())
    }

    @Test fun activeAndPausedRecordingCannotBeDeletedAsSavedFile() {
        val record = service()
        val file = audio()
        assertTrue(record.startManual("fictional", "manual", file))
        rejects { record.deleteSavedRecording(file.path) }
        record.pause()
        rejects { record.deleteSavedRecording(file.path) }
        assertTrue(file.exists())
        assertEquals(true, record.getStatus()["isRecording"])
        assertEquals(true, record.getStatus()["isPaused"])
    }

    @Test fun discardRefusesStaleSessionAndPreservesCurrentRecording() {
        val record = service()
        val file = audio()
        assertTrue(record.startManual("fictional", "current", file))
        rejects { record.discardRecording("previous") }
        assertTrue(file.exists())
        assertEquals(true, record.getStatus()["isRecording"])
        assertFalse(repository.isDiscardRequested(file))
    }

    @Test fun discardAutomaticRecordingDoesNotEmitUploadEvent() {
        val record = service()
        val session = "rec_auto_fictional_1234567890123"
        val file = audio(session)
        val events = mutableListOf<String>()
        record.setEventListener { type, _ -> events.add(type) }
        assertTrue(record.start(session, file))
        assertTrue(record.discardRecording(session))
        assertFalse(file.exists())
        assertFalse(events.contains("autoStopped"))
        assertEquals(false, record.getStatus()["isRecording"])
        assertFalse(repository.isDiscardRequested(file))
    }

    @Test fun ordinaryAutomaticStopStillEmitsUploadEvent() {
        val record = service()
        val file = audio("rec_auto_fictional_1234567890123")
        val events = mutableListOf<String>()
        record.setEventListener { type, _ -> events.add(type) }
        assertTrue(record.start("rec_auto_fictional_1234567890123", file))
        record.stop()
        assertTrue(file.exists())
        assertEquals(listOf("autoStopped"), events)
    }

    @Test fun discardIntentSurvivesRepositoryRecreationUntilDeletion() {
        val file = audio()
        repository.markDiscardRequested(file.path)
        val recreated = RecordingRepository(app)
        assertTrue(recreated.isDiscardRequested(file))
        assertTrue(recreated.scanUnfinishedRecordings().contains(file))
        recreated.deleteAudioFile(file.path)
        assertFalse(RecordingRepository(app).isDiscardRequested(file))
    }

    @Test fun channelReportsValidationFailureInsteadOfSuccess() {
        val plugin = RecordingBridgePlugin()
        RecordingBridgePlugin::class.java.getDeclaredField("repository")
            .apply { isAccessible = true }.set(plugin, repository)
        var error: String? = null
        var success = false
        val outside = File(app.getExternalFilesDir(null), "outside-channel.m4a").apply { writeText("keep") }
        plugin.onMethodCall(MethodCall("deleteRecordingFile", mapOf("filePath" to outside.path)),
            object : MethodChannel.Result {
                override fun success(result: Any?) { success = true }
                override fun error(code: String, message: String?, details: Any?) { error = code }
                override fun notImplemented() { fail("Method must be implemented") }
            })
        assertFalse(success)
        assertEquals("RECORDING_DELETE_FAILED", error)
        assertEquals("keep", outside.readText())
    }
}
