package expo.modules.inappdebugger

import android.app.Application
import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Build
import android.os.Process as AndroidProcess
import android.system.Os
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.Closeable
import java.io.File
import java.io.FileDescriptor
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStreamReader
import java.io.PrintWriter
import java.io.StringWriter
import java.lang.ref.WeakReference
import java.nio.charset.StandardCharsets
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.Locale
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

private const val CRASH_REPORT_FILE = "expo-inapp-debugger-last-native-crash-android.log"
private const val CRASH_HISTORY_FILE = "expo-inapp-debugger-native-crash-history-android.json"
private const val STATUS_CONTEXT = "android-native-status"
private const val LOGCAT_CONTEXT = "logcat"
private const val STDOUT_FD = 1
private const val STDERR_FD = 2
private const val MAX_CRASH_HISTORY = 6
private const val LOGCAT_PID_OPTION_MIN_SDK = 24

object InAppDebuggerNativeLogCapture {
  private val lock = Any()
  private var appContextRef: WeakReference<Context>? = null
  private var debugConfig = DebugConfig()
  private var nativeConfig = AndroidNativeLogsConfig()
  private var captureEnabled = false
  private var crashReplayLoaded = false
  private var originalUncaughtExceptionHandler: Thread.UncaughtExceptionHandler? = null
  private var uncaughtExceptionHandlerInstalled = false
  private var stdoutCapture: StreamCaptureHandle? = null
  private var stderrCapture: StreamCaptureHandle? = null
  private var appLogcatReader: LogcatReaderHandle? = null
  private var rootLogcatReader: LogcatReaderHandle? = null
  private var activeLogcatMode = "disabled"
  private var rootStatus = "not_requested"
  private var rootDetails: String? = null
  private var rootProbeInFlight = false
  private var crashHistory = emptyList<DebugCrashRecord>()

  fun applyConfig(context: Context?, config: DebugConfig) {
    synchronized(lock) {
      val previousContext = appContextRef?.get()
      val nextConfig = sanitizeConfig(config.androidNativeLogs)
      val nextCaptureEnabled = config.enabled && nextConfig.enabled

      updateContextLocked(context)
      val resolvedContext = appContextRef?.get()
      debugConfig = config
      val shouldRefresh =
        nativeConfig != nextConfig ||
          captureEnabled != nextCaptureEnabled ||
        (resolvedContext != null && resolvedContext !== previousContext)

      nativeConfig = nextConfig
      captureEnabled = nextCaptureEnabled
      if (shouldRefresh) {
        refreshCaptureStateLocked()
      } else {
        publishRuntimeInfoLocked()
      }
    }
  }

  fun updateContext(context: Context?) {
    synchronized(lock) {
      val previousContext = appContextRef?.get()
      updateContextLocked(context)
      val resolvedContext = appContextRef?.get()
      if (captureEnabled && resolvedContext != null && resolvedContext !== previousContext) {
        refreshCaptureStateLocked()
      } else if (resolvedContext !== previousContext) {
        publishRuntimeInfoLocked()
      }
    }
  }

  fun refreshRuntimeInfo(forceRootProbe: Boolean = false) {
    synchronized(lock) {
      if (forceRootProbe) {
        ensureRootStatusProbeLocked(force = true)
      }
      publishRuntimeInfoLocked()
    }
  }

  fun shutdown() {
    synchronized(lock) {
      captureEnabled = false
      activeLogcatMode = "disabled"
      stopAllLocked()
      restoreUncaughtExceptionHandlerLocked()
      publishRuntimeInfoLocked()
    }
  }

  private fun sanitizeConfig(config: AndroidNativeLogsConfig): AndroidNativeLogsConfig {
    val buffers = config.buffers.filterTo(linkedSetOf()) {
      it in setOf("main", "system", "crash", "events", "radio")
    }.ifEmpty {
      linkedSetOf("main", "system", "crash")
    }.toList()

    return config.copy(
      logcatScope = if (config.logcatScope == "device") "device" else "app",
      rootMode = if (config.rootMode == "auto") "auto" else "off",
      buffers = buffers
    )
  }

  private fun refreshCaptureStateLocked() {
    stopAllLocked()
    activeLogcatMode = "disabled"

    if (!captureEnabled) {
      restoreUncaughtExceptionHandlerLocked()
      publishRuntimeInfoLocked()
      return
    }

    val context = appContextRef?.get()
    if (context == null) {
      InAppDebuggerStore.appendNativeLog(
        createNativeDebugLogEntry(
          type = "warn",
          message = "Android native log capture is waiting for an application context.",
          context = STATUS_CONTEXT,
          details = "collector=native-log-capture"
        )
      )
      publishRuntimeInfoLocked()
      return
    }

    if (nativeConfig.captureUncaughtExceptions) {
      installUncaughtExceptionHandlerLocked(context)
    } else {
      restoreUncaughtExceptionHandlerLocked()
    }

    if (nativeConfig.captureStdoutStderr) {
      stdoutCapture = startStreamCaptureLocked("stdout", FileDescriptor.out, "log")
      stderrCapture = startStreamCaptureLocked("stderr", FileDescriptor.err, "error")
    }

    if (nativeConfig.captureLogcat) {
      if (nativeConfig.logcatScope == "device") {
        if (nativeConfig.rootMode == "auto") {
          rootLogcatReader = startLogcatReaderLocked(
            mode = "root-device",
            useRoot = true,
            filterPid = null,
            fallbackToAppScope = true
          )
        } else {
          appendStatusLocked(
            type = "warn",
            message = "Android device-wide logcat capture requires root. Falling back to app-only logcat.",
            details = "scope=device rootMode=off buffers=${nativeConfig.buffers.joinToString(",")}"
          )
          appLogcatReader = startLogcatReaderLocked(
            mode = "app",
            useRoot = false,
            filterPid = AndroidProcess.myPid(),
            fallbackToAppScope = false
          )
        }
      } else {
        appLogcatReader = startLogcatReaderLocked(
          mode = "app",
          useRoot = false,
          filterPid = AndroidProcess.myPid(),
          fallbackToAppScope = false
        )
      }
    }

    if (nativeConfig.rootMode == "auto") {
      ensureRootStatusProbeLocked(force = false)
    }

    appendStatusLocked(
      type = "info",
      message = "Android native log capture is active.",
      details = buildString {
        appendLine("captureLogcat=${nativeConfig.captureLogcat}")
        appendLine("captureStdoutStderr=${nativeConfig.captureStdoutStderr}")
        appendLine("captureUncaughtExceptions=${nativeConfig.captureUncaughtExceptions}")
        appendLine("logcatScope=${nativeConfig.logcatScope}")
        appendLine("rootMode=${nativeConfig.rootMode}")
        append("buffers=${nativeConfig.buffers.joinToString(",")}")
      }
    )
    publishRuntimeInfoLocked()
  }

  private fun updateContextLocked(context: Context?) {
    if (context != null) {
      appContextRef = WeakReference(context.applicationContext)
    }
    val actualContext = appContextRef?.get() ?: return
    crashHistory = loadCrashHistory(actualContext)
    if (crashReplayLoaded) {
      return
    }

    replayPersistedCrashReportIfNeeded(actualContext)
    crashReplayLoaded = true
  }

  private fun stopAllLocked() {
    stopStreamCaptureLocked(stdoutCapture)
    stopStreamCaptureLocked(stderrCapture)
    stdoutCapture = null
    stderrCapture = null

    stopLogcatReaderLocked(appLogcatReader)
    stopLogcatReaderLocked(rootLogcatReader)
    appLogcatReader = null
    rootLogcatReader = null
  }

  private fun publishRuntimeInfoLocked() {
    InAppDebuggerStore.updateRuntimeInfo(buildRuntimeInfoLocked())
  }

  private fun buildRuntimeInfoLocked(): DebugRuntimeInfo {
    val context = appContextRef?.get()
    val appInfo = context?.applicationInfo
    val packageManager = context?.packageManager
    val packageName = context?.packageName.orEmpty()
    val packageInfo = context?.let { safePackageInfo(it) }
    val appName =
      if (appInfo != null && packageManager != null) {
        appInfo.loadLabel(packageManager)?.toString().orEmpty()
      } else {
        ""
      }
    val processName =
      when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.P -> Application.getProcessName().orEmpty()
        !appInfo?.processName.isNullOrBlank() -> appInfo?.processName.orEmpty()
        else -> packageName
      }

    return DebugRuntimeInfo(
      appName = appName,
      packageName = packageName,
      versionName = packageInfo?.versionName.orEmpty(),
      versionCode = packageInfo?.longVersionCode,
      processName = processName,
      pid = AndroidProcess.myPid(),
      uid = AndroidProcess.myUid(),
      debuggable = (appInfo?.flags ?: 0 and ApplicationInfo.FLAG_DEBUGGABLE) != 0,
      targetSdk = appInfo?.targetSdkVersion ?: 0,
      minSdk = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) appInfo?.minSdkVersion ?: 0 else 0,
      manufacturer = Build.MANUFACTURER.orEmpty(),
      brand = Build.BRAND.orEmpty(),
      deviceModel = listOfNotNull(Build.MANUFACTURER, Build.MODEL).joinToString(" ").trim(),
      sdkInt = Build.VERSION.SDK_INT,
      release = Build.VERSION.RELEASE.orEmpty(),
      supportedAbis = Build.SUPPORTED_ABIS?.toList() ?: emptyList(),
      networkTabEnabled = debugConfig.enableNetworkTab,
      nativeLogsEnabled = captureEnabled,
      captureLogcat = captureEnabled && nativeConfig.captureLogcat,
      captureStdoutStderr = captureEnabled && nativeConfig.captureStdoutStderr,
      captureUncaughtExceptions = captureEnabled && nativeConfig.captureUncaughtExceptions,
      requestedLogcatScope = nativeConfig.logcatScope,
      requestedRootMode = nativeConfig.rootMode,
      activeLogcatMode = activeLogcatMode,
      rootStatus = rootStatus,
      rootDetails = rootDetails,
      buffers = nativeConfig.buffers,
      crashRecords = crashHistory
    )
  }

  private fun safePackageInfo(context: Context): android.content.pm.PackageInfo? {
    return try {
      val packageManager = context.packageManager
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        packageManager.getPackageInfo(
          context.packageName,
          android.content.pm.PackageManager.PackageInfoFlags.of(0)
        )
      } else {
        @Suppress("DEPRECATION")
        packageManager.getPackageInfo(context.packageName, 0)
      }
    } catch (_: Throwable) {
      null
    }
  }

  private fun ensureRootStatusProbeLocked(force: Boolean) {
    if (rootProbeInFlight) {
      return
    }
    if (!force && rootStatus !in setOf("not_requested", "unknown")) {
      return
    }

    rootProbeInFlight = true
    rootStatus = "checking"
    rootDetails = null
    publishRuntimeInfoLocked()

    thread(start = true, isDaemon = true, name = "InAppDebugger-root-probe") {
      val result = probeRootStatus()
      synchronized(lock) {
        rootProbeInFlight = false
        rootStatus = result.status
        rootDetails = result.details
        publishRuntimeInfoLocked()
      }
    }
  }

  private fun probeRootStatus(): RootProbeResult {
    return try {
      val process = ProcessBuilder("su", "-c", "id")
        .redirectErrorStream(true)
        .start()

      val completed = process.waitFor(1500, TimeUnit.MILLISECONDS)
      if (!completed) {
        process.destroyForcibly()
        return RootProbeResult(
          status = "unknown",
          details = "Timed out while waiting for root confirmation."
        )
      }

      val output = process.inputStream.bufferedReader(StandardCharsets.UTF_8).use { it.readText().trim() }
      if (process.exitValue() == 0 && output.contains("uid=0")) {
        RootProbeResult(status = "root", details = output.ifBlank { "uid=0" })
      } else {
        RootProbeResult(
          status = "non_root",
          details = output.ifBlank { "Root shell was not granted." }
        )
      }
    } catch (error: Throwable) {
      RootProbeResult(
        status = "non_root",
        details = error.message ?: error.javaClass.simpleName
      )
    }
  }

  private fun installUncaughtExceptionHandlerLocked(context: Context) {
    if (uncaughtExceptionHandlerInstalled) {
      return
    }

    originalUncaughtExceptionHandler = Thread.getDefaultUncaughtExceptionHandler()
    Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
      try {
        val crashRecord = createCrashRecord(thread, throwable)
        persistCrashReport(context, crashRecord)
        appendCrashHistoryLocked(context, crashRecord)
        InAppDebuggerStore.appendNativeLog(
          createNativeDebugLogEntry(
            type = "error",
            message = throwable.message ?: "Uncaught exception",
            context = "uncaught-exception",
            details = buildString {
              appendLine("thread=${thread.name}")
              appendLine("exception=${throwable.javaClass.name}")
              append(stackTraceString(throwable))
            }
          )
        )
      } catch (_: Throwable) {
        // Best-effort crash reporting only.
      }

      val original = originalUncaughtExceptionHandler
      if (original != null) {
        original.uncaughtException(thread, throwable)
      } else {
        AndroidProcess.killProcess(AndroidProcess.myPid())
        kotlin.system.exitProcess(10)
      }
    }
    uncaughtExceptionHandlerInstalled = true
  }

  private fun restoreUncaughtExceptionHandlerLocked() {
    if (!uncaughtExceptionHandlerInstalled) {
      return
    }
    Thread.setDefaultUncaughtExceptionHandler(originalUncaughtExceptionHandler)
    uncaughtExceptionHandlerInstalled = false
    originalUncaughtExceptionHandler = null
  }

  private fun startStreamCaptureLocked(
    streamName: String,
    targetDescriptor: FileDescriptor,
    defaultLevel: String
  ): StreamCaptureHandle? {
    return try {
      val originalDescriptor = Os.dup(targetDescriptor)
      val pipe = Os.pipe()
      val targetFdNumber = if (targetDescriptor == FileDescriptor.out) STDOUT_FD else STDERR_FD
      Os.dup2(pipe[1], targetFdNumber)
      Os.close(pipe[1])

      val readStream = FileInputStream(pipe[0])
      val passthroughStream = FileOutputStream(originalDescriptor)
      val handle = StreamCaptureHandle(
        streamName = streamName,
        targetDescriptor = targetDescriptor,
        targetFdNumber = targetFdNumber,
        originalDescriptor = originalDescriptor,
        readStream = readStream,
        passthroughStream = passthroughStream,
        defaultLevel = defaultLevel
      )
      handle.readerThread = thread(
        start = true,
        isDaemon = true,
        name = "InAppDebugger-$streamName-capture"
      ) {
        runStreamReader(handle)
      }
      handle
    } catch (error: Throwable) {
      InAppDebuggerStore.appendNativeLog(
        createNativeDebugLogEntry(
          type = "warn",
          message = "Failed to start Android $streamName capture.",
          context = STATUS_CONTEXT,
          details = error.stackTraceToString()
        )
      )
      null
    }
  }

  private fun runStreamReader(handle: StreamCaptureHandle) {
    val buffer = ByteArray(4096)
    val partial = StringBuilder()

    try {
      while (handle.running) {
        val count = handle.readStream.read(buffer)
        if (count <= 0) {
          break
        }

        handle.passthroughStream.write(buffer, 0, count)
        handle.passthroughStream.flush()

        val entries = appendLinesFromChunk(
          partial = partial,
          chunk = String(buffer, 0, count, StandardCharsets.UTF_8),
          defaultLevel = handle.defaultLevel,
          context = handle.streamName,
          detailsBuilder = { null }
        )
        if (entries.isNotEmpty()) {
          InAppDebuggerStore.appendNativeLogs(entries)
        }
      }
    } catch (_: IOException) {
      // Expected when the stream is restored and the pipe gets closed.
    } finally {
      flushPartialLine(partial, handle.defaultLevel, handle.streamName, null)?.let {
        InAppDebuggerStore.appendNativeLog(it)
      }
      closeQuietly(handle.readStream)
      closeQuietly(handle.passthroughStream)
    }
  }

  private fun stopStreamCaptureLocked(handle: StreamCaptureHandle?) {
    handle ?: return

    handle.running = false
    try {
      if (handle.targetDescriptor == FileDescriptor.out) {
        System.out.flush()
      } else if (handle.targetDescriptor == FileDescriptor.err) {
        System.err.flush()
      }
    } catch (_: Throwable) {
      // Ignore flush failures while restoring the stream.
    }

    try {
      Os.dup2(handle.originalDescriptor, handle.targetFdNumber)
    } catch (_: Throwable) {
      // Best effort.
    }

    closeQuietly(handle.readStream)
    closeQuietly(handle.passthroughStream)
    handle.readerThread?.interrupt()
    handle.readerThread?.join(150)
  }

  private fun startLogcatReaderLocked(
    mode: String,
    useRoot: Boolean,
    filterPid: Int?,
    fallbackToAppScope: Boolean,
    preferPidOption: Boolean = true
  ): LogcatReaderHandle? {
    val context = appContextRef?.get()
    val usePidOption =
      !useRoot &&
        filterPid != null &&
        preferPidOption &&
        Build.VERSION.SDK_INT >= LOGCAT_PID_OPTION_MIN_SDK
    val baseCommand = buildLogcatCommand(nativeConfig.buffers, filterPid, usePidOption)
    val command = if (useRoot) {
      listOf("su", "-c", shellCommand(baseCommand))
    } else {
      baseCommand
    }

    val process = try {
      ProcessBuilder(command)
        .directory(context?.cacheDir)
        .redirectErrorStream(true)
        .start()
    } catch (error: Throwable) {
      appendStatusLocked(
        type = "warn",
        message = "Failed to start Android logcat capture.",
        details = buildString {
          appendLine("mode=$mode useRoot=$useRoot")
          append(error.stackTraceToString())
        }
      )
      if (fallbackToAppScope) {
        appLogcatReader = startLogcatReaderLocked(
          mode = "app-fallback",
          useRoot = false,
          filterPid = AndroidProcess.myPid(),
          fallbackToAppScope = false
        )
      }
      return null
    }

    val handle = LogcatReaderHandle(
      mode = mode,
      useRoot = useRoot,
      filterPid = filterPid,
      usedPidOption = usePidOption,
      fallbackToAppScope = fallbackToAppScope,
      detailsPrefix = buildLogcatDetailsPrefix(mode, useRoot),
      process = process
    )
    activeLogcatMode = mode
    publishRuntimeInfoLocked()
    handle.readerThread = thread(
      start = true,
      isDaemon = true,
      name = "InAppDebugger-logcat-$mode"
    ) {
      runLogcatReader(handle)
    }
    return handle
  }

  private fun runLogcatReader(handle: LogcatReaderHandle) {
    var exitCode = 0
    val startupNoise = StringBuilder()
    val batch = ArrayList<DebugLogEntry>(32)

    try {
      BufferedReader(InputStreamReader(handle.process.inputStream, StandardCharsets.UTF_8)).use { reader ->
        while (handle.running) {
          val line = reader.readLine() ?: break
          val parsed = parseLogcatLine(line)
          if (parsed == null) {
            if (startupNoise.length < 4096) {
              startupNoise.appendLine(line)
            }
            continue
          }

          if (handle.filterPid != null && parsed.pid != handle.filterPid) {
            continue
          }

          batch.add(
            createNativeDebugLogEntry(
            type = levelForPriority(parsed.priority),
            message = parsed.message,
            context = parsed.tag.ifBlank { LOGCAT_CONTEXT },
            details = buildLogcatDetails(handle.detailsPrefix, parsed.priority, parsed.pid, parsed.tid),
            timestampMillis = parsed.timestampMillis
            )
          )

          if (batch.size >= 32) {
            InAppDebuggerStore.appendNativeLogs(ArrayList(batch))
            batch.clear()
          }
        }
      }
    } catch (_: IOException) {
      // Expected when the process is destroyed during shutdown.
    } finally {
      if (batch.isNotEmpty()) {
        InAppDebuggerStore.appendNativeLogs(batch.toList())
        batch.clear()
      }

      exitCode = try {
        handle.process.waitFor()
      } catch (_: InterruptedException) {
        0
      }

      val shouldReport = handle.running
      handle.running = false
      handle.process.destroy()

      if (shouldReport) {
        synchronized(lock) {
          if (handle.useRoot && rootLogcatReader === handle) {
            rootLogcatReader = null
          } else if (!handle.useRoot && appLogcatReader === handle) {
            appLogcatReader = null
          }
          if (activeLogcatMode == handle.mode) {
            activeLogcatMode = "disabled"
          }

          if (handle.useRoot && exitCode != 0 && rootStatus != "root") {
            rootStatus = "non_root"
            rootDetails = startupNoise.toString().trim().ifBlank {
              "Root logcat failed with exit code $exitCode."
            }
          }

          val shouldRetryWithoutPidOption =
            handle.usedPidOption &&
              handle.filterPid != null &&
              shouldRetryLogcatWithoutPidOption(exitCode, startupNoise.toString())

          if (shouldRetryWithoutPidOption && captureEnabled && nativeConfig.captureLogcat) {
            appendStatusLocked(
              type = "warn",
              message = "Android logcat pid filter is unavailable. Falling back to in-process filtering.",
              details = buildString {
                appendLine("mode=${handle.mode}")
                appendLine("pid=${handle.filterPid}")
                appendLine("exitCode=$exitCode")
                append(startupNoise.toString().trim())
              }
            )
            appLogcatReader = startLogcatReaderLocked(
              mode = handle.mode,
              useRoot = false,
              filterPid = handle.filterPid,
              fallbackToAppScope = handle.fallbackToAppScope,
              preferPidOption = false
            )
            publishRuntimeInfoLocked()
            return@synchronized
          }

          appendStatusLocked(
            type = if (exitCode == 0) "warn" else "error",
            message = "Android logcat reader stopped.",
            details = buildString {
              appendLine("mode=${handle.mode}")
              appendLine("useRoot=${handle.useRoot}")
              appendLine("exitCode=$exitCode")
              if (startupNoise.isNotBlank()) {
                append(startupNoise.toString().trim())
              }
            }
          )

          if (handle.fallbackToAppScope && captureEnabled && nativeConfig.captureLogcat) {
            appLogcatReader = startLogcatReaderLocked(
              mode = "app-fallback",
              useRoot = false,
              filterPid = AndroidProcess.myPid(),
              fallbackToAppScope = false
            )
          }
          publishRuntimeInfoLocked()
        }
      }
    }
  }

  private fun stopLogcatReaderLocked(handle: LogcatReaderHandle?) {
    handle ?: return
    handle.running = false
    handle.process.destroy()
    handle.readerThread?.interrupt()
    handle.readerThread?.join(250)
  }

  private fun replayPersistedCrashReportIfNeeded(context: Context) {
    val crashFile = crashReportFile(context)
    if (!crashFile.exists()) {
      return
    }

    val payload = try {
      crashFile.readText()
    } catch (_: Throwable) {
      ""
    }

    crashFile.delete()

    if (payload.isBlank()) {
      return
    }

    val parts = payload.split("\n---\n", limit = 5)
    val timestampMillis = parts.getOrNull(0)?.toLongOrNull() ?: System.currentTimeMillis()
    val threadName = parts.getOrNull(1).orEmpty()
    val exceptionClass = parts.getOrNull(2).orEmpty()
    val exceptionMessage = parts.getOrNull(3).orEmpty()
    val stackTrace = parts.getOrNull(4).orEmpty()
    val crashRecord = createCrashRecord(
      timestampMillis = timestampMillis,
      threadName = threadName,
      exceptionClass = exceptionClass,
      message = exceptionMessage,
      stackTrace = stackTrace
    )

    if (crashHistory.none { it.id == crashRecord.id }) {
      appendCrashHistoryLocked(context, crashRecord)
    }

    InAppDebuggerStore.appendNativeLog(
      createNativeDebugLogEntry(
        type = "error",
        message = if (exceptionMessage.isNotBlank()) {
          exceptionMessage
        } else {
          "Recovered uncaught exception from the previous Android process run."
        },
        context = "uncaught-exception",
        details = buildString {
          appendLine("replayed=true")
          if (threadName.isNotBlank()) {
            appendLine("thread=$threadName")
          }
          if (exceptionClass.isNotBlank()) {
            appendLine("exception=$exceptionClass")
          }
          if (stackTrace.isNotBlank()) {
            append(stackTrace)
          }
        },
        timestampMillis = timestampMillis
      )
    )
  }

  private fun persistCrashReport(context: Context, crashRecord: DebugCrashRecord) {
    val crashFile = crashReportFile(context)
    val payload = buildString {
      append(crashRecord.timestampMillis)
      append("\n---\n")
      append(crashRecord.threadName)
      append("\n---\n")
      append(crashRecord.exceptionClass)
      append("\n---\n")
      append(crashRecord.message)
      append("\n---\n")
      append(crashRecord.stackTrace)
    }
    crashFile.writeText(payload)
  }

  private fun crashReportFile(context: Context): File = File(context.cacheDir, CRASH_REPORT_FILE)
  private fun crashHistoryFile(context: Context): File = File(context.cacheDir, CRASH_HISTORY_FILE)

  private fun appendStatusLocked(type: String, message: String, details: String) {
    InAppDebuggerStore.appendNativeLog(
      createNativeDebugLogEntry(
        type = type,
        message = message,
        context = STATUS_CONTEXT,
        details = details
      )
    )
  }

  private fun appendLinesFromChunk(
    partial: StringBuilder,
    chunk: String,
    defaultLevel: String,
    context: String,
    detailsBuilder: (String) -> String?
  ): List<DebugLogEntry> {
    if (chunk.isEmpty()) {
      return emptyList()
    }

    val entries = ArrayList<DebugLogEntry>()
    var segmentStart = 0
    while (segmentStart < chunk.length) {
      val newlineIndex = chunk.indexOf('\n', segmentStart)
      if (newlineIndex < 0) {
        partial.append(chunk, segmentStart, chunk.length)
        break
      }

      val lineEnd = if (newlineIndex > segmentStart && chunk[newlineIndex - 1] == '\r') {
        newlineIndex - 1
      } else {
        newlineIndex
      }
      val line = materializeChunkLine(partial, chunk, segmentStart, lineEnd)
      segmentStart = newlineIndex + 1
      if (line == null) {
        continue
      }

      entries.add(
        createNativeDebugLogEntry(
          type = defaultLevel,
          message = line,
          context = context,
          details = detailsBuilder(line)
        )
      )
    }
    return entries
  }

  private fun flushPartialLine(
    partial: StringBuilder,
    defaultLevel: String,
    context: String,
    details: String?
  ): DebugLogEntry? {
    val remaining = partial.toString().trim()
    if (remaining.isBlank()) {
      return null
    }

    return createNativeDebugLogEntry(
      type = defaultLevel,
      message = remaining,
      context = context,
      details = details
    )
  }

  private fun buildLogcatCommand(
    buffers: List<String>,
    filterPid: Int?,
    usePidOption: Boolean
  ): List<String> {
    val command = mutableListOf("logcat")
    buffers.forEach { buffer ->
      command += listOf("-b", buffer)
    }
    if (usePidOption && filterPid != null) {
      command += listOf("--pid", filterPid.toString())
    }
    command += listOf("-v", "threadtime", "-T", "1")
    return command
  }

  private fun shellCommand(arguments: List<String>): String {
    return arguments.joinToString(" ") { argument ->
      if (argument.all { it.isLetterOrDigit() || it == '-' || it == '_' || it == '/' || it == '.' }) {
        argument
      } else {
        "'${argument.replace("'", "'\\''")}'"
      }
    }
  }

  private fun shouldRetryLogcatWithoutPidOption(exitCode: Int, startupNoise: String): Boolean {
    if (exitCode == 0 || startupNoise.isBlank()) {
      return false
    }
    val normalizedNoise = startupNoise.lowercase(Locale.ROOT)
    if (!normalizedNoise.contains("pid")) {
      return false
    }
    return normalizedNoise.contains("unknown option") ||
      normalizedNoise.contains("invalid option") ||
      normalizedNoise.contains("unrecognized option") ||
      normalizedNoise.contains("unsupported")
  }

  private fun parseLogcatLine(line: String): ParsedLogcatLine? {
    if (line.length < 24 ||
      !line.hasDigitPairAt(0) ||
      line.getOrNull(2) != '-' ||
      !line.hasDigitPairAt(3) ||
      line.getOrNull(5) != ' ' ||
      !line.hasDigitPairAt(6) ||
      line.getOrNull(8) != ':' ||
      !line.hasDigitPairAt(9) ||
      line.getOrNull(11) != ':' ||
      !line.hasDigitPairAt(12) ||
      line.getOrNull(14) != '.' ||
      !line.hasDigitTripleAt(15)
    ) {
      return null
    }

    val month = line.parseTwoDigits(0) ?: return null
    val day = line.parseTwoDigits(3) ?: return null
    val hour = line.parseTwoDigits(6) ?: return null
    val minute = line.parseTwoDigits(9) ?: return null
    val second = line.parseTwoDigits(12) ?: return null
    val millisecond = line.parseThreeDigits(15) ?: return null
    if (month !in 1..12 ||
      day !in 1..31 ||
      hour !in 0..23 ||
      minute !in 0..59 ||
      second !in 0..59 ||
      millisecond !in 0..999
    ) {
      return null
    }
    var cursor = 18
    if (line.getOrNull(cursor)?.isWhitespace() != true) {
      return null
    }
    cursor = line.skipWhitespace(cursor)
    val pidEnd = line.findTokenEnd(cursor)
    val pid = line.parsePositiveInt(cursor, pidEnd) ?: return null
    cursor = line.skipWhitespace(pidEnd)
    val tidEnd = line.findTokenEnd(cursor)
    val tid = line.parsePositiveInt(cursor, tidEnd) ?: return null
    cursor = line.skipWhitespace(tidEnd)
    val priorityChar = line.getOrNull(cursor) ?: return null
    if (priorityChar !in LOGCAT_PRIORITIES) {
      return null
    }
    cursor += 1
    if (line.getOrNull(cursor)?.isWhitespace() != true) {
      return null
    }
    cursor = line.skipWhitespace(cursor)
    val separatorIndex = line.indexOf(": ", startIndex = cursor)
    if (separatorIndex <= cursor) {
      return null
    }

    val tag = line.substring(cursor, separatorIndex).trim()
    val message = line.substring(separatorIndex + 2)
    val timestampMillis = resolveLogcatTimestamp(
      month = month,
      day = day,
      hour = hour,
      minute = minute,
      second = second,
      millisecond = millisecond
    )
    return ParsedLogcatLine(
      timestampMillis = timestampMillis,
      pid = pid,
      tid = tid,
      priority = priorityChar.toString(),
      tag = tag,
      message = message
    )
  }

  private fun resolveLogcatTimestamp(
    month: Int,
    day: Int,
    hour: Int,
    minute: Int,
    second: Int,
    millisecond: Int
  ): Long {
    val now = LocalDateTime.now()
    var candidate = LocalDateTime.of(
      now.year,
      month,
      day,
      hour,
      minute,
      second,
      millisecond * 1_000_000
    )

    if (candidate.isAfter(now.plusDays(1))) {
      candidate = candidate.minusYears(1)
    }

    return candidate.atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
  }

  private fun levelForPriority(priority: String): String {
    return when (priority) {
      "V", "D" -> "debug"
      "I" -> "info"
      "W" -> "warn"
      else -> "error"
    }
  }

  private fun stackTraceString(throwable: Throwable): String {
    val writer = StringWriter()
    PrintWriter(writer).use { printWriter ->
      throwable.printStackTrace(printWriter)
    }
    return writer.toString()
  }

  private fun createCrashRecord(thread: Thread, throwable: Throwable): DebugCrashRecord {
    return createCrashRecord(
      timestampMillis = System.currentTimeMillis(),
      threadName = thread.name,
      exceptionClass = throwable.javaClass.name,
      message = throwable.message.orEmpty(),
      stackTrace = stackTraceString(throwable)
    )
  }

  private fun createCrashRecord(
    timestampMillis: Long,
    threadName: String,
    exceptionClass: String,
    message: String,
    stackTrace: String
  ): DebugCrashRecord {
    val normalizedMessage = message.ifBlank {
      exceptionClass.ifBlank { "Uncaught exception" }
    }
    return DebugCrashRecord(
      id = buildCrashRecordId(timestampMillis, threadName, exceptionClass, normalizedMessage),
      timestampMillis = timestampMillis,
      threadName = threadName,
      exceptionClass = exceptionClass,
      message = normalizedMessage,
      stackTrace = stackTrace
    )
  }

  private fun buildCrashRecordId(
    timestampMillis: Long,
    threadName: String,
    exceptionClass: String,
    message: String
  ): String {
    val fingerprint = "$threadName|$exceptionClass|$message".hashCode()
    return "crash_${timestampMillis}_$fingerprint"
  }

  private fun appendCrashHistoryLocked(context: Context, crashRecord: DebugCrashRecord) {
    synchronized(lock) {
      crashHistory = buildList {
        add(crashRecord)
        crashHistory.forEach { existing ->
          if (existing.id != crashRecord.id) {
            add(existing)
          }
        }
      }.take(MAX_CRASH_HISTORY)
      persistCrashHistory(context, crashHistory)
      publishRuntimeInfoLocked()
    }
  }

  private fun loadCrashHistory(context: Context): List<DebugCrashRecord> {
    val crashFile = crashHistoryFile(context)
    if (!crashFile.exists()) {
      return emptyList()
    }

    val raw = try {
      crashFile.readText()
    } catch (_: Throwable) {
      return emptyList()
    }

    if (raw.isBlank()) {
      return emptyList()
    }

    return try {
      val array = JSONArray(raw)
      buildList {
        for (index in 0 until array.length()) {
          val item = array.optJSONObject(index) ?: continue
          parseCrashRecord(item)?.let(::add)
        }
      }.sortedByDescending(DebugCrashRecord::timestampMillis).take(MAX_CRASH_HISTORY)
    } catch (_: Throwable) {
      emptyList()
    }
  }

  private fun persistCrashHistory(context: Context, history: List<DebugCrashRecord>) {
    val payload = JSONArray().apply {
      history.forEach { put(it.toJson()) }
    }
    crashHistoryFile(context).writeText(payload.toString())
  }

  private fun parseCrashRecord(json: JSONObject): DebugCrashRecord? {
    val timestampMillis = json.optLong("timestampMillis", 0L)
    if (timestampMillis <= 0L) {
      return null
    }

    val threadName = json.optString("threadName", "")
    val exceptionClass = json.optString("exceptionClass", "")
    val message = json.optString("message", "")
    val stackTrace = json.optString("stackTrace", "")
    return DebugCrashRecord(
      id = json.optString(
        "id",
        buildCrashRecordId(timestampMillis, threadName, exceptionClass, message)
      ),
      timestampMillis = timestampMillis,
      threadName = threadName,
      exceptionClass = exceptionClass,
      message = message,
      stackTrace = stackTrace
    )
  }

  private fun DebugCrashRecord.toJson(): JSONObject {
    return JSONObject().apply {
      put("id", id)
      put("timestampMillis", timestampMillis)
      put("threadName", threadName)
      put("exceptionClass", exceptionClass)
      put("message", message)
      put("stackTrace", stackTrace)
    }
  }

  private fun closeQuietly(closeable: Closeable?) {
    try {
      closeable?.close()
    } catch (_: Throwable) {
      // Ignore close failures during shutdown.
    }
  }
}

private fun buildLogcatDetailsPrefix(mode: String, useRoot: Boolean): String {
  return buildString(mode.length + 32) {
    append("source=")
    append(if (useRoot) "root-logcat" else "logcat")
    append('\n')
    append("mode=")
    append(mode)
    append('\n')
    append("priority=")
  }
}

private fun buildLogcatDetails(prefix: String, priority: String, pid: Int, tid: Int): String {
  return buildString(prefix.length + 24) {
    append(prefix)
    append(priority)
    append('\n')
    append("pid=")
    append(pid)
    append('\n')
    append("tid=")
    append(tid)
  }
}

private fun materializeChunkLine(
  partial: StringBuilder,
  chunk: String,
  start: Int,
  end: Int
): String? {
  if (partial.isEmpty()) {
    return if (chunk.isBlankRange(start, end)) {
      null
    } else {
      chunk.substring(start, end)
    }
  }

  partial.append(chunk, start, end)
  val line = partial.toString()
  partial.setLength(0)
  return if (line.isBlank()) null else line
}

private fun String.skipWhitespace(startIndex: Int): Int {
  var cursor = startIndex
  while (cursor < length && this[cursor].isWhitespace()) {
    cursor += 1
  }
  return cursor
}

private fun String.findTokenEnd(startIndex: Int): Int {
  var cursor = startIndex
  while (cursor < length && !this[cursor].isWhitespace()) {
    cursor += 1
  }
  return cursor
}

private fun String.parsePositiveInt(startIndex: Int, endIndex: Int): Int? {
  if (startIndex >= endIndex || endIndex > length) {
    return null
  }
  var result = 0
  for (index in startIndex until endIndex) {
    val digit = this[index] - '0'
    if (digit !in 0..9) {
      return null
    }
    result = result * 10 + digit
  }
  return result
}

private fun String.parseTwoDigits(startIndex: Int): Int? = parsePositiveInt(startIndex, startIndex + 2)

private fun String.parseThreeDigits(startIndex: Int): Int? = parsePositiveInt(startIndex, startIndex + 3)

private fun String.hasDigitPairAt(startIndex: Int): Boolean {
  return getOrNull(startIndex)?.isDigit() == true && getOrNull(startIndex + 1)?.isDigit() == true
}

private fun String.hasDigitTripleAt(startIndex: Int): Boolean {
  return getOrNull(startIndex)?.isDigit() == true &&
    getOrNull(startIndex + 1)?.isDigit() == true &&
    getOrNull(startIndex + 2)?.isDigit() == true
}

private fun String.isBlankRange(startIndex: Int, endIndex: Int): Boolean {
  for (index in startIndex until endIndex) {
    if (!this[index].isWhitespace()) {
      return false
    }
  }
  return true
}

private val LOGCAT_PRIORITIES = charArrayOf('V', 'D', 'I', 'W', 'E', 'F', 'A')

private data class StreamCaptureHandle(
  val streamName: String,
  val targetDescriptor: FileDescriptor,
  val targetFdNumber: Int,
  val originalDescriptor: FileDescriptor,
  val readStream: FileInputStream,
  val passthroughStream: FileOutputStream,
  val defaultLevel: String,
  @Volatile var running: Boolean = true,
  @Volatile var readerThread: Thread? = null
)

private data class LogcatReaderHandle(
  val mode: String,
  val useRoot: Boolean,
  val filterPid: Int?,
  val usedPidOption: Boolean,
  val fallbackToAppScope: Boolean,
  val detailsPrefix: String,
  val process: java.lang.Process,
  @Volatile var running: Boolean = true,
  @Volatile var readerThread: Thread? = null
)

private data class ParsedLogcatLine(
  val timestampMillis: Long,
  val pid: Int,
  val tid: Int,
  val priority: String,
  val tag: String,
  val message: String
)

private data class RootProbeResult(
  val status: String,
  val details: String?
)
