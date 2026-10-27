package audio

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Flutter Platform Channel 原生录音插件。
 * 绑定 MethodChannel("class_notes/audio_recorder") 与 EventChannel("class_notes/audio_recorder_events")。
 */
class RecordingBridgePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler, ActivityAware, PluginRegistry.RequestPermissionsResultListener {

    private lateinit var context: Context
    private var activity: Activity? = null
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null

    private lateinit var repository: RecordingRepository
    private var audioService: AudioRecordService? = null
    private var isBound = false

    private var pendingStart: Pair<MethodCall, MethodChannel.Result>? = null

    private var pendingPermissionResult: MethodChannel.Result? = null

    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            val binder = service as? AudioRecordService.LocalBinder
            audioService = binder?.getService()
            isBound = true
            pendingStart?.let { (call, result) ->
                pendingStart = null
                onMethodCall(call, result)
            }
            audioService?.setEventListener { type, data ->
                activity?.runOnUiThread {
                    eventSink?.success(mapOf("type" to type, "payload" to data))
                }
            }
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            audioService = null
            isBound = false
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        repository = RecordingRepository(context)

        methodChannel = MethodChannel(binding.binaryMessenger, "class_notes/audio_recorder")
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, "class_notes/audio_recorder_events")
        eventChannel.setStreamHandler(this)

        bindAudioService()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        unbindAudioService()
    }

    private fun bindAudioService() {
        val intent = Intent(context, AudioRecordService::class.java)
        context.bindService(intent, serviceConnection, Context.BIND_AUTO_CREATE)
    }

    private fun unbindAudioService() {
        if (isBound) {
            context.unbindService(serviceConnection)
            isBound = false
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "checkPermissions" -> {
                result.success(checkAllPermissions())
            }
            "requestPermissions" -> {
                requestAllPermissions(result)
            }
            "openAutoStartSettings" -> {
                RomWhitelistHelper.openAutoStartSettings(context)
                result.success(null)
            }
            "openBatterySettings" -> {
                RomWhitelistHelper.openBatterySettings(context)
                result.success(null)
            }
            "startRecording" -> {
                if (audioService == null) {
                    if (pendingStart != null) { result.error("BUSY", "录音正在启动", null); return }
                    pendingStart = call to result
                    if (!isBound) bindAudioService()
                    android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                        if (pendingStart?.second === result) {
                            pendingStart = null
                            result.error("SERVICE_UNAVAILABLE", "录音服务未就绪，请重试", null)
                        }
                    }, 3000)
                    return
                }
                val courseId = call.argument<String>("courseId") ?: "unknown"
                val codec = call.argument<String>("codec") ?: "aac"
                val sessionId = "rec_${courseId}_${System.currentTimeMillis()}"
                val file = repository.createAudioFile(sessionId, codec)

                val ok = audioService?.startManual(courseId, sessionId, file) ?: false
                if (ok) {
                    try { context.startService(Intent(context, AudioRecordService::class.java)) }
                    catch (e: Exception) { audioService?.stop(); result.error("SERVICE_START_FAILED", e.message, null); return }
                }
                if (ok) {
                    result.success(mapOf(
                        "sessionId" to sessionId,
                        "filePath" to file.absolutePath,
                        "startedAtMs" to System.currentTimeMillis(),
                        "codec" to codec
                    ))
                } else {
                    result.error("SERVICE_START_FAILED", "无法启动录音前台服务", null)
                }
            }
            "pauseRecording" -> {
                audioService?.pause()
                result.success(null)
            }
            "resumeRecording" -> {
                audioService?.resume()
                result.success(null)
            }
            "stopRecording" -> {
                val res = audioService?.stop() ?: emptyMap()
                result.success(res)
            }
            "cancelRecording" -> {
                audioService?.cancel()
                result.success(null)
            }
            "getStatus" -> {
                result.success(audioService?.getStatus() ?: mapOf("isRecording" to false))
            }
            "listRecordingFiles" -> {
                // The binder may still be connecting while the service records.
                val status = AudioRecordService.activeInstance?.getStatus() ?: audioService?.getStatus()
                val active = (status?.get("sessionId") as? String)
                    ?.takeIf { status["isRecording"] == true }
                val items = repository.scanUnfinishedRecordings().filter { file ->
                    active == null || !file.name.contains(active)
                }.map { file ->
                    val match = Regex("^rec_(rec_auto_|rec_)?(.+?)_(\\d{13})_(\\d{8})_\\d{6}\\.(m4a|wav)$")
                        .matchEntire(file.name)
                    val courseId = match?.groupValues?.get(2) ?: ""
                    val date = match?.groupValues?.get(4)?.let { "${it.substring(0,4)}-${it.substring(4,6)}-${it.substring(6,8)}" } ?: ""
                    mapOf("filePath" to file.absolutePath, "courseId" to courseId,
                        "classDate" to date, "sizeBytes" to file.length())
                }
                result.success(items)
            }
            "syncScheduleAlarms" -> {
                val alarms = call.argument<List<Map<String, Any?>>>("alarms") ?: emptyList()
                if (!AutoRecordAlarmStore.schedule(context, alarms)) {
                    result.success(false)
                    return
                }
                if (alarms.isNotEmpty()) {
                    try {
                        ContextCompat.startForegroundService(context,
                            Intent(context, AudioRecordService::class.java).apply { action = AudioRecordService.ACTION_ARM })
                        AudioRecordService.activeInstance?.arm()
                    } catch (e: Exception) {
                        result.error("ARM_FAILED", e.message, null)
                        return
                    }
                } else if (AudioRecordService.activeInstance != null) {
                    context.startService(Intent(context, AudioRecordService::class.java).apply { action = AudioRecordService.ACTION_DISARM })
                }
                result.success(true)
            }
            "installApk" -> {
                val filePath = call.argument<String>("filePath")
                if (filePath != null) {
                    val file = java.io.File(filePath)
                    if (file.exists()) {
                        val uri = androidx.core.content.FileProvider.getUriForFile(
                            context,
                            "${context.packageName}.fileprovider",
                            file
                        )
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION
                        }
                        context.startActivity(intent)
                        result.success(true)
                    } else {
                        result.error("FILE_NOT_FOUND", "安装包文件不存在", null)
                    }
                } else {
                    result.error("INVALID_ARGS", "路径不能为空", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun checkAllPermissions(): Map<String, Boolean> {
        val mic = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        val notif = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        } else true

        val fg = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            ContextCompat.checkSelfPermission(context, Manifest.permission.FOREGROUND_SERVICE) == PackageManager.PERMISSION_GRANTED
        } else true

        val battery = RomWhitelistHelper.isBatteryOptimizationIgnored(context)

        return mapOf(
            "recordAudio" to mic,
            "notifications" to notif,
            "foregroundService" to fg,
            "batteryUnrestricted" to battery,
            "autoStartEnabled" to false // No public API can confirm MIUI autostart.
        )
    }

    private fun requestAllPermissions(result: MethodChannel.Result) {
        val act = activity
        if (act == null) {
            result.success(checkAllPermissions())
            return
        }

        val needed = mutableListOf<String>()
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            needed.add(Manifest.permission.RECORD_AUDIO)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            needed.add(Manifest.permission.POST_NOTIFICATIONS)
        }

        if (needed.isEmpty()) {
            result.success(checkAllPermissions())
        } else {
            pendingPermissionResult = result
            ActivityCompat.requestPermissions(act, needed.toTypedArray(), 1001)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode == 1001) {
            pendingPermissionResult?.success(checkAllPermissions())
            pendingPermissionResult = null
            return true
        }
        return false
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        this.eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        this.eventSink = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activity = null
    }
}
