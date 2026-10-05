package com.filetoolkit

import android.app.DownloadManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Environment
import android.os.SystemClock
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import android.content.BroadcastReceiver
import android.content.IntentFilter
import android.os.Build
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.WritableMap
import com.facebook.react.modules.core.DeviceEventManagerModule
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLDecoder
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.concurrent.thread
import android.webkit.MimeTypeMap

// ─── Per-download state ───────────────────────────────────────────────────────

/** State of one foreground download. The promise lives here, not in a map keyed
 *  by downloadId, so a reused id can never settle another download's promise. */
private class DownloadState(val promise: Promise) {
  @Volatile var paused: Boolean = false
  @Volatile var cancelled: Boolean = false
  /** Connection currently in use, so pause/cancel can disconnect a blocked read. */
  @Volatile var connection: HttpURLConnection? = null
  private val outcome = AtomicReference<String?>(null)

  /**
   * The single running → finished transition ([OUTCOME_COMPLETED],
   * [OUTCOME_FAILED] or [OUTCOME_CANCELLED]). Returns true for exactly one
   * caller, who then owns settling [promise].
   */
  fun claim(result: String): Boolean = outcome.compareAndSet(null, result)
  val result: String? get() = outcome.get()

  /** Bumped by every [interrupt], so the thread can tell a forced disconnect
   *  from a real EOF/error even if the flags were already reset by a resume. */
  val interrupts = AtomicInteger()

  /** Unblocks a read/connect in progress; the download thread then checks the flags. */
  fun interrupt() {
    interrupts.incrementAndGet()
    try { connection?.disconnect() } catch (_: Exception) {}
  }
}

private const val OUTCOME_COMPLETED = "COMPLETED"
private const val OUTCOME_FAILED = "FAILED"
private const val OUTCOME_CANCELLED = "CANCELLED"

/** ".<name>.<uuid>.part" — see [FileToolkitModule.download]. */
private val PARTIAL_FILE_NAME = Regex("""\..*\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.part""")

/** "bytes <start>-<end>/<total|*>" */
private val CONTENT_RANGE = Regex("""bytes\s+(\d+)-(\d+)/(\d+|\*)""", RegexOption.IGNORE_CASE)

class FileToolkitModule(private val reactContext: ReactApplicationContext) :
  NativeFileToolkitSpec(reactContext) {

  // downloadId → state (foreground downloads only)
  private val activeDownloads = ConcurrentHashMap<String, DownloadState>()
  // downloadId → background DownloadManager ID
  private val bgDownloadIds = ConcurrentHashMap<String, Long>()
  // Absolute paths of partial files owned by a running foreground download thread
  // (including one that was cancelled but has not cleaned up yet).
  private val livePartFiles: MutableSet<String> = ConcurrentHashMap.newKeySet()

  /**
   * Single background thread for everything DownloadManager-related: polling,
   * finalisation and checksum verification. DownloadManager.query is a
   * ContentProvider round-trip and hashing a large file takes seconds; neither
   * may run on the main thread. Being single-threaded also serialises
   * [finalizeBackground] calls coming from the poller and the receiver.
   */
  private val bgExecutor = Executors.newSingleThreadScheduledExecutor { r ->
    Thread(r, "FileToolkit-bg").apply { isDaemon = true }
  }
  // Guarded by bgExecutor.
  private var bgPollFuture: ScheduledFuture<*>? = null

  private val downloadReceiver = object : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
      if (intent?.action == DownloadManager.ACTION_DOWNLOAD_COMPLETE) {
        val id = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1L)
        // The receiver is exported (DownloadManager is another app), so the
        // broadcast may be forged: finalizeBackground re-queries the real status.
        runOnBgExecutor { finalizeBackground(id) }
      }
    }
  }

  /**
   * Background terminal events emitted before JS subscribed to them (e.g. a
   * download that finished while the process was dead and is reported right
   * after launch) would otherwise be dropped by RCTDeviceEventEmitter. They are
   * held here until the first addListener() for that event name. Foreground
   * events are never buffered: their promise already reports the outcome.
   * Guarded by itself.
   */
  private val pendingEvents = ArrayDeque<Pair<String, WritableMap>>()
  // Guarded by pendingEvents.
  private val subscribedEvents = HashSet<String>()
  private val maxPendingEvents = 100

  /**
   * Persistent DownloadManager id → toolkit downloadId mapping.
   *
   * Background downloads outlive the process, so the mapping cannot live only in
   * memory. It also must not live in the notification description: callers can
   * override that via `notificationDescription`, which used to silently break
   * every progress/complete event for the download.
   *
   * Keys: "<bgId>" → downloadId, and "<bgId>.checksum" → "<ALGORITHM>:<hash>".
   */
  private val bgPrefs by lazy {
    reactContext.getSharedPreferences("rn_file_toolkit_bg", Context.MODE_PRIVATE)
  }

  private fun rememberBackgroundDownload(downloadId: String, bgId: Long, checksum: String?) {
    bgDownloadIds[downloadId] = bgId
    bgPrefs.edit().apply {
      putString(bgId.toString(), downloadId)
      if (checksum != null) putString("$bgId.checksum", checksum)
    }.apply()
  }

  /** Stops tracking a background download. Returns false if it was not (or no longer) tracked. */
  private fun forgetBackgroundDownload(downloadId: String, bgId: Long): Boolean {
    val removed = bgDownloadIds.remove(downloadId, bgId)
    bgPrefs.edit().remove(bgId.toString()).remove("$bgId.checksum").apply()
    return removed
  }

  /** Resolves a DownloadManager id back to the toolkit downloadId, or null. */
  private fun downloadIdForBgId(bgId: Long): String? {
    bgDownloadIds.entries.firstOrNull { it.value == bgId }?.let { return it.key }
    return bgPrefs.getString(bgId.toString(), null)
  }

  init {
    // Re-adopt downloads started before the process was killed. Their completion
    // broadcast may have been sent while we were dead, so polling picks them up.
    try {
      bgPrefs.all.forEach { (key, value) ->
        val bgId = key.toLongOrNull()
        if (bgId != null && value is String) bgDownloadIds[value] = bgId
      }
    } catch (_: Exception) {}

    val filter = IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      reactContext.registerReceiver(downloadReceiver, filter, Context.RECEIVER_EXPORTED)
    } else {
      reactContext.registerReceiver(downloadReceiver, filter)
    }
    if (bgDownloadIds.isNotEmpty()) ensureBackgroundPolling()
    // Partial files whose thread died with the process are never cleaned up
    // otherwise. None can be live yet, but check anyway.
    runOnBgExecutor {
      for (dir in toolkitDirs()) {
        dir.listFiles()?.forEach { f ->
          if (f.isFile && isPartialFile(f) && f.absolutePath !in livePartFiles) f.delete()
        }
      }
    }
  }

  override fun invalidate() {
    super.invalidate()
    try {
      reactContext.unregisterReceiver(downloadReceiver)
    } catch (_: Exception) {} // Receiver may not be registered
    synchronized(bgExecutor) {
      bgPollFuture?.cancel(false)
      bgPollFuture = null
      bgExecutor.shutdownNow()
    }
    // Stop foreground download threads and settle their promises, otherwise a dev
    // reload leaves orphaned threads writing files for a bridge that is gone.
    activeDownloads.forEach { (id, state) ->
      state.cancelled = true
      state.interrupt()
      if (state.claim(OUTCOME_CANCELLED)) state.promise.resolve(cancelledResult(id))
    }
    activeDownloads.clear()
  }

  override fun addListener(eventName: String?) {
    // Called by NativeEventEmitter for every JS subscription. The first one for
    // an event name releases whatever was buffered for it.
    if (eventName == null) return
    val flush = synchronized(pendingEvents) {
      if (!subscribedEvents.add(eventName)) return
      val matching = pendingEvents.filter { it.first == eventName }
      pendingEvents.removeAll { it.first == eventName }
      matching
    }
    flush.forEach { (event, map) -> sendEvent(event, map) }
  }

  override fun removeListeners(count: Double) {
    // No-op: buffering only needs to know that JS subscribed once. Events after
    // the last listener is removed are dropped, as before.
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────

  /** [bufferUntilSubscribed]: only for background (DownloadManager) terminal events. */
  private fun emit(event: String, map: WritableMap, bufferUntilSubscribed: Boolean = false) {
    if (bufferUntilSubscribed) {
      synchronized(pendingEvents) {
        if (event !in subscribedEvents) {
          pendingEvents.addLast(event to map)
          if (pendingEvents.size > maxPendingEvents) pendingEvents.removeFirst()
          return
        }
      }
    }
    sendEvent(event, map)
  }

  private fun sendEvent(event: String, map: WritableMap) {
    // Downloads run on background threads and can outlive the React instance
    // (dev reload, activity teardown). Emitting into a dead instance throws and
    // crashes the app, so bail out instead.
    if (!reactContext.hasActiveReactInstance()) return
    try {
      reactContext
        .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
        .emit(event, map)
    } catch (_: Exception) {
      // React instance torn down between the check and the emit — nothing to do.
    }
  }

  private fun cancelledResult(downloadId: String): WritableMap = Arguments.createMap().apply {
    putBoolean("success", false)
    putString("downloadId", downloadId)
    putString("error", "CANCELLED")
  }

  /**
   * Reduces an arbitrary name to a single, safe path segment.
   *
   * A file name is attacker- or server-controlled (it can come from the URL, a
   * redirect target or a caller-supplied `fileName`), so `../` sequences and
   * embedded separators must never be able to escape the destination directory.
   */
  private fun sanitizeFileName(name: String): String {
    // Strip any directory component, then neutralise traversal and separators.
    val base = name.substringAfterLast('/').substringAfterLast('\\')
    val cleaned = base.trim()
    if (cleaned.isBlank() || cleaned == "." || cleaned == "..") return "downloaded_file"
    // Keep names within the common filesystem limit.
    return if (cleaned.length > 200) cleaned.takeLast(200) else cleaned
  }

  private fun resolveFileName(url: String, hint: String?): String {
    if (!hint.isNullOrBlank()) return sanitizeFileName(hint)
    var name = url.substringBefore("#").substringBefore("?").substringAfterLast("/")
    name = try {
      URLDecoder.decode(name, "UTF-8")
    } catch (_: Exception) {
      name
    }
    return sanitizeFileName(name)
  }

  /** Resolves the toolkit-owned directory for a logical destination. */
  private fun getDestinationDir(destination: String?): File {
    val dir = when (destination) {
      "cache" -> File(reactContext.cacheDir, "RNFileToolkit")
      // getExternalFilesDir can return null if external storage is unavailable
      "documents" -> File(
        reactContext.getExternalFilesDir(Environment.DIRECTORY_DOCUMENTS) ?: reactContext.filesDir,
        "RNFileToolkit"
      )
      // Use app-specific downloads directory to avoid scoped storage issues on Android 10+
      else -> File(
        reactContext.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: reactContext.filesDir,
        "RNFileToolkit"
      )
    }
    dir.mkdirs()
    return dir
  }

  /**
   * Destination directory for background (DownloadManager) downloads.
   *
   * DownloadManager runs in a different process and cannot write to the app's
   * *internal* cache dir, so "cache" maps to the external cache dir instead.
   * [getCachedFiles] and [clearCache] scan both so the two paths stay in sync.
   */
  private fun getBackgroundDestinationDir(destination: String?): File {
    if (destination != "cache") return getDestinationDir(destination)
    val dir = File(reactContext.externalCacheDir ?: reactContext.cacheDir, "RNFileToolkit")
    dir.mkdirs()
    return dir
  }

  /** Every directory the toolkit may write downloads into. */
  private fun toolkitDirs(): List<File> = listOf(
    File(reactContext.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: reactContext.filesDir, "RNFileToolkit"),
    File(reactContext.cacheDir, "RNFileToolkit"),
    File(reactContext.externalCacheDir ?: reactContext.cacheDir, "RNFileToolkit"),
    File(reactContext.getExternalFilesDir(Environment.DIRECTORY_DOCUMENTS) ?: reactContext.filesDir, "RNFileToolkit")
  ).distinctBy { it.absolutePath }

  /** In-progress foreground download (see [download]); never a finished file. */
  private fun isPartialFile(f: File) = PARTIAL_FILE_NAME.matches(f.name)

  private fun getDestinationFile(fileName: String, destination: String?): File {
    return File(getDestinationDir(destination), sanitizeFileName(fileName))
  }

  private fun calculateChecksum(file: File, algorithm: String): String {
    val javaAlgo = when (algorithm.uppercase()) {
      "SHA1" -> "SHA-1"
      "SHA256" -> "SHA-256"
      else -> algorithm
    }
    val digest = MessageDigest.getInstance(javaAlgo)
    val fis = FileInputStream(file)
    try {
      val buffer = ByteArray(8192)
      var count: Int
      while (fis.read(buffer).also { count = it } != -1) {
        digest.update(buffer, 0, count)
      }
    } finally {
      fis.close()
    }
    val bytes = digest.digest()
    return bytes.joinToString("") { "%02x".format(it) }
  }

  /** Connect timeout for every HTTP request this module makes, in milliseconds. */
  private val connectTimeoutMs = 30_000
  /** Socket read timeout, in milliseconds. */
  private val readTimeoutMs = 60_000

  /**
   * Opens a connected [HttpURLConnection] for a download.
   *
   * Handles two things `HttpURLConnection` does not do on its own:
   * - **Timeouts.** The platform default is *no* timeout, so a stalled server
   *   leaves the download thread and its JS promise hanging forever.
   * - **Cross-protocol redirects.** `HttpURLConnection` silently refuses to
   *   follow http→https (and https→http) redirects, which is exactly what CDNs
   *   and pre-signed storage URLs use. Without this the caller sees an empty
   *   file or a 30x "server error".
   * - **Credentials on redirect.** Every redirect is followed here, under one
   *   policy: once the origin changes (scheme, host or port — so including an
   *   https→http downgrade), `Authorization`, `Cookie` and
   *   `Proxy-Authorization` are no longer sent. The platform only drops
   *   `Authorization`, and only for the redirects it follows itself.
   */
  private fun openDownloadConnection(
    urlString: String,
    headersMap: ReadableMap?,
    resumeFrom: Long,
    ifRange: String? = null,
    state: DownloadState? = null
  ): HttpURLConnection {
    val originalUrl = URL(urlString)
    var currentUrl = originalUrl
    var redirects = 0
    while (true) {
      val sameOrigin = currentUrl.protocol.equals(originalUrl.protocol, ignoreCase = true) &&
        currentUrl.host.equals(originalUrl.host, ignoreCase = true) &&
        currentUrl.port.let { if (it == -1) currentUrl.defaultPort else it } ==
        originalUrl.port.let { if (it == -1) originalUrl.defaultPort else it }
      val connection = currentUrl.openConnection() as HttpURLConnection
      connection.connectTimeout = connectTimeoutMs
      connection.readTimeout = readTimeoutMs
      connection.instanceFollowRedirects = false
      // Ask for an unencoded body: HttpURLConnection transparently gunzips a
      // gzipped response but still reports the *compressed* Content-Length,
      // which makes progress percentages run past 100%.
      connection.setRequestProperty("Accept-Encoding", "identity")

      headersMap?.toHashMap()?.forEach { (key, value) ->
        if (value is String && (sameOrigin || key.lowercase() !in CREDENTIAL_HEADERS)) {
          connection.setRequestProperty(key, value)
        }
      }
      if (resumeFrom > 0) {
        connection.setRequestProperty("Range", "bytes=$resumeFrom-")
        // If the resource changed since the partial was written, the server
        // answers 200 with the full body instead of splicing mismatched bytes.
        if (ifRange != null) connection.setRequestProperty("If-Range", ifRange)
      }
      if (state != null) {
        // Publish before connecting so pause/cancel can abort a stalled connect.
        // Re-check afterwards: either they see this connection or we see the flag.
        state.connection = connection
        if (state.paused || state.cancelled) {
          connection.disconnect()
          throw java.io.IOException("Download paused or cancelled")
        }
      }
      connection.connect()

      val code = connection.responseCode
      val isRedirect = code == HttpURLConnection.HTTP_MOVED_PERM ||
        code == HttpURLConnection.HTTP_MOVED_TEMP ||
        code == HttpURLConnection.HTTP_SEE_OTHER ||
        code == 307 || code == 308
      val location = connection.getHeaderField("Location")
      if (!isRedirect || location == null || redirects >= MAX_REDIRECTS) return connection

      connection.disconnect()
      currentUrl = URL(currentUrl, location)
      redirects++
    }
  }

  // ─── download ──────────────────────────────────────────────────────────────

  override fun download(options: ReadableMap, promise: Promise) {
    val urlString = options.getString("url")
    if (urlString.isNullOrBlank()) {
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", false); putString("error", "URL is missing")
      })
      return
    }

    val isBackground = options.takeIf { it.hasKey("background") }?.getBoolean("background") ?: false
    val rawFileName = if (options.hasKey("fileName")) options.getString("fileName") else null
    val fileName = resolveFileName(urlString, rawFileName)
    val downloadId = if (options.hasKey("downloadId")) options.getString("downloadId")!! else UUID.randomUUID().toString()

    val headersMap = options.getMap("headers")
    val destination = options.takeIf { it.hasKey("destination") }?.getString("destination")
    val notificationTitle = options.takeIf { it.hasKey("notificationTitle") }?.getString("notificationTitle")
    val notificationDesc = options.takeIf { it.hasKey("notificationDescription") }?.getString("notificationDescription")
    val checksumMap = options.takeIf { it.hasKey("checksum") }?.getMap("checksum")

    // ─── Retry config ──────────────────────────────────────────────────────
    val retryMap = options.takeIf { it.hasKey("retry") && !it.isNull("retry") }?.getMap("retry")
    val maxAttempts = retryMap?.takeIf { it.hasKey("attempts") && !it.isNull("attempts") }?.getInt("attempts") ?: 0
    // hasKey alone is not enough: `delay: undefined` can arrive as an explicit null.
    // 0 is a valid delay (retry immediately).
    val baseDelay = retryMap?.takeIf { it.hasKey("delay") && !it.isNull("delay") }
      ?.getDouble("delay")?.toLong()?.coerceAtLeast(0L) ?: 1000L

    // A downloadId is a handle for pause/resume/cancel and events, so it must
    // be unique among running downloads. cancelDownload frees it synchronously.
    val idInUse = Arguments.createMap().apply {
      putBoolean("success", false)
      putString("downloadId", downloadId)
      putString("error", "DOWNLOAD_ID_IN_USE")
    }
    if (activeDownloads.containsKey(downloadId) || bgDownloadIds.containsKey(downloadId)) {
      promise.resolve(idInUse)
      return
    }

    if (isBackground) {
      // Use system DownloadManager — survives process death
      try {
        val dm = reactContext.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        val request = DownloadManager.Request(Uri.parse(urlString)).apply {
          setTitle(notificationTitle ?: fileName)
          if (notificationDesc != null) setDescription(notificationDesc)
          setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)

          // Add headers
          headersMap?.toHashMap()?.forEach { (key, value) ->
            if (value is String) addRequestHeader(key, value)
          }

          // Set destination — mirror the RNFileToolkit subdirectory used by getDestinationFile
          setDestinationUri(Uri.fromFile(File(getBackgroundDestinationDir(destination), fileName)))
        }
        // Persisted with the id so the checksum is still verified when the
        // download finishes after a process restart.
        val checksum = checksumMap?.let { m ->
          m.getString("hash")?.let { hash -> "${m.getString("algorithm")?.uppercase() ?: "MD5"}:$hash" }
        }
        val bgId = dm.enqueue(request)
        rememberBackgroundDownload(downloadId, bgId, checksum)
        ensureBackgroundPolling()

        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", true)
          putString("downloadId", downloadId)
        })
      } catch (e: Exception) {
        // DownloadManager rejects unsupported schemes (file://, data:) and can be
        // disabled by the user, both of which throw rather than returning an id.
        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", false)
          putString("downloadId", downloadId)
          putString("error", e.message ?: "DOWNLOAD_MANAGER_ERROR")
        })
      }
      return
    }

    // Foreground: the promise is resolved on completion (matches iOS behaviour).
    // Every exit path — completion, failure, cancelDownload, invalidate — goes
    // through state.claim(), so it is settled exactly once.
    val state = DownloadState(promise)
    if (activeDownloads.putIfAbsent(downloadId, state) != null) {
      promise.resolve(idInUse)
      return
    }

    thread {
      fun fail(error: String, claimed: Boolean = false) {
        if (!claimed && !state.claim(OUTCOME_FAILED)) return
        state.promise.resolve(Arguments.createMap().apply {
          putBoolean("success", false)
          putString("downloadId", downloadId)
          putString("error", error)
        })
        emit("onDownloadError", Arguments.createMap().apply {
          putBoolean("success", false)
          putString("downloadId", downloadId)
          putString("error", error)
        })
      }

      fun settleCancelled() {
        if (state.claim(OUTCOME_CANCELLED)) state.promise.resolve(cancelledResult(downloadId))
      }

      val destDir: File
      try {
        destDir = getDestinationDir(destination)
      } catch (e: Exception) {
        activeDownloads.remove(downloadId, state)
        fail(e.message ?: "NETWORK_ERROR")
        return@thread
      }
      val destFile = File(destDir, fileName)
      // Each download writes to its own hidden partial file and is renamed into
      // place only once complete and verified, so two downloads of the same name
      // never interleave and a cancel only ever deletes its own bytes.
      val partFile = File(destDir, ".${fileName.take(64)}.${UUID.randomUUID()}.part")
      // Registered before the file exists so clearCache / the startup sweep never
      // delete it from under us.
      livePartFiles.add(partFile.absolutePath)

      try {
        var attempt = 0
        var retryPending = false
        var lastError = "NETWORK_ERROR"
        // Strong validator of the full response, sent as If-Range when resuming.
        var validator: String? = null

        retryLoop@ while (true) {
          // ── Before retry: emit event + wait with exponential backoff ───────
          if (retryPending) {
            retryPending = false
            val delayMs = (minOf(baseDelay, 30_000L) * (1L shl minOf(attempt - 1, 20))).coerceAtMost(30_000L)
            // Bug #5 fix: emit retry event BEFORE the delay so JS callback fires immediately
            val retryEvt = Arguments.createMap().apply {
              putString("downloadId", downloadId)
              putString("url", urlString)
              putInt("attempt", attempt)
              putString("error", lastError)
            }
            emit("onDownloadRetry", retryEvt)
            // Interruptible retry delay — respects cancel
            val deadline = System.currentTimeMillis() + delayMs
            while (!state.cancelled && System.currentTimeMillis() < deadline) {
              Thread.sleep(minOf(deadline - System.currentTimeMillis(), 100L).coerceAtLeast(0L))
            }
          }
          // Paused: the connection is already closed and the partial file kept,
          // so a pause of any length is fine. Wait (still honouring cancel).
          while (state.paused && !state.cancelled) {
            Thread.sleep(100L)
          }
          if (state.cancelled) {
            settleCancelled()
            return@thread
          }

          // Resume from what is actually on disk (0 when there is no partial).
          val resumeFrom = partFile.length()
          var connection: HttpURLConnection? = null
          var finished = false
          val interruptsBefore = state.interrupts.get()

          try {
            val conn = openDownloadConnection(urlString, headersMap, resumeFrom, validator, state)
            connection = conn

            val responseCode = conn.responseCode
            if (responseCode == 416 && resumeFrom > 0) {
              // Partial no longer satisfiable (resource changed/shrank): start over.
              partFile.delete()
              continue@retryLoop
            }
            if (responseCode != HttpURLConnection.HTTP_OK && responseCode != HttpURLConnection.HTTP_PARTIAL) {
              // Server error — do NOT retry (4xx/5xx are not transient)
              fail("SERVER_ERROR: $responseCode")
              return@thread
            }

            val contentLength = conn.getHeaderField("Content-Length")?.toLongOrNull() ?: -1L
            val append: Boolean
            val totalExpected: Long
            if (responseCode == HttpURLConnection.HTTP_PARTIAL && resumeFrom > 0) {
              val contentRange = conn.getHeaderField("Content-Range")
              val rangeMatch = contentRange?.let { CONTENT_RANGE.find(it) }
              if (rangeMatch?.groupValues?.get(1)?.toLongOrNull() != resumeFrom) {
                // Missing, unparseable or not the range we asked for — the bytes
                // cannot be spliced on safely, so restart from 0 (without Range).
                partFile.delete()
                continue@retryLoop
              }
              append = true
              totalExpected = rangeMatch?.groupValues?.get(3)?.toLongOrNull()
                ?: if (contentLength >= 0) resumeFrom + contentLength else -1L
            } else {
              // Full body (no Range sent, or the server ignored it): start from 0.
              append = false
              totalExpected = contentLength
              validator = conn.getHeaderField("ETag")?.takeUnless { it.startsWith("W/") }
                ?: conn.getHeaderField("Last-Modified")
            }

            var input: InputStream? = null
            var output: FileOutputStream? = null
            try {
              input = conn.inputStream
              output = FileOutputStream(partFile, append)
              val buffer = ByteArray(8192)
              var total = if (append) resumeFrom else 0L
              var lastProgress = -1
              var lastUnknownProgressAt = 0L

              // On pause or cancel, stop reading and close the connection; the
              // partial stays on disk and is resumed with a Range request.
              while (!state.cancelled && !state.paused) {
                val count = input.read(buffer)
                if (count == -1) {
                  val sizeOk = totalExpected < 0 || total == totalExpected
                  if (state.interrupts.get() != interruptsBefore) {
                    // A forced disconnect (pause/cancel) can look like EOF on a body
                    // without a length; only trust it if the size is known and matches.
                    finished = totalExpected >= 0 && sizeOk
                    break
                  }
                  if (!sizeOk) {
                    // Short (or long) body: retry via Range if attempts remain.
                    throw java.io.IOException("INCOMPLETE_DOWNLOAD: received $total of $totalExpected bytes")
                  }
                  finished = true
                  break
                }
                output.write(buffer, 0, count)
                total += count

                if (totalExpected > 0) {
                  val progress = (total * 100 / totalExpected).toInt()
                  if (progress > lastProgress) {
                    lastProgress = progress
                    val evt = Arguments.createMap().apply {
                      putString("url", urlString)
                      putString("downloadId", downloadId)
                      putInt("progress", progress)
                      putDouble("bytesDownloaded", total.toDouble())
                      putDouble("totalBytes", totalExpected.toDouble())
                    }
                    emit("onDownloadProgress", evt)
                  }
                } else {
                  // Unknown size (no Content-Length): report bytes only, throttled.
                  val now = SystemClock.elapsedRealtime()
                  if (now - lastUnknownProgressAt >= 250L) {
                    lastUnknownProgressAt = now
                    val evt = Arguments.createMap().apply {
                      putString("url", urlString)
                      putString("downloadId", downloadId)
                      putInt("progress", -1)
                      putDouble("bytesDownloaded", total.toDouble())
                      putDouble("totalBytes", -1.0)
                    }
                    emit("onDownloadProgress", evt)
                  }
                }
              }
              output.flush()
            } finally {
              // Bug #1 fix: guaranteed close regardless of exception
              try { output?.close() } catch (_: Exception) {}
              try { input?.close() } catch (_: Exception) {}
            }
          } catch (e: Exception) {
            // Check the flags first: pause/cancel disconnect the connection, which
            // surfaces here as an IOException that is not a network error.
            if (state.cancelled) {
              settleCancelled()
              return@thread
            }
            // Paused (or paused and already resumed): wait for resume if needed,
            // then continue via Range. No retry consumed.
            if (state.paused || state.interrupts.get() != interruptsBefore) continue@retryLoop
            lastError = e.message ?: "NETWORK_ERROR"   // Bug #3 fix: save error for next retry event
            // Network error — retry if attempts remain. The partial file is kept
            // and the retry resumes from its length.
            if (attempt < maxAttempts) {
              attempt++
              retryPending = true
              continue@retryLoop
            }
            fail(lastError)
            return@thread
          } finally {
            state.connection = null
            connection?.disconnect()
          }

          if (state.cancelled) {
            settleCancelled()
            return@thread
          }
          if (finished) break@retryLoop
          // Paused mid-body: loop back, wait for resume, reconnect with Range.
        }

        // ── Checksum verification ─────────────────────────────────────────
        // Failures here are terminal: re-downloading cannot fix a wrong expected
        // hash or an unsupported algorithm.
        if (checksumMap != null) {
          val expectedHash = checksumMap.getString("hash")
          val algorithm = checksumMap.getString("algorithm")?.uppercase() ?: "MD5"
          if (expectedHash != null) {
            val actualHash = try {
              calculateChecksum(partFile, algorithm)
            } catch (e: Exception) {
              fail(e.message ?: "CHECKSUM_ERROR")
              return@thread
            }
            if (!actualHash.equals(expectedHash, ignoreCase = true)) {
              fail("CHECKSUM_MISMATCH: expected $expectedHash, got $actualHash")
              return@thread
            }
          }
        }

        if (state.cancelled) {
          settleCancelled()
          return@thread
        }
        // Commit point. If cancel claimed first it wins: the partial is deleted
        // in finally and the existing file is untouched. Otherwise cancelDownload
        // now reports ALREADY_COMPLETED.
        if (!state.claim(OUTCOME_COMPLETED)) return@thread

        // rename(2) atomically replaces an existing file of the same name.
        // No delete-then-rename fallback: if the rename fails, the user's existing
        // file must stay intact.
        if (!partFile.renameTo(destFile)) {
          fail("Could not move downloaded file to ${destFile.absolutePath}", claimed = true)
          return@thread
        }
        state.promise.resolve(Arguments.createMap().apply {
          putBoolean("success", true)
          putString("downloadId", downloadId)
          putString("filePath", destFile.absolutePath)
        })
        // onDownloadComplete is only emitted for background downloads (matches iOS);
        // a foreground download reports completion through its promise.
      } catch (e: Throwable) {
        // InterruptedException, OOM, … — never leave the promise hanging.
        fail(e.message ?: "NETWORK_ERROR")
      } finally {
        // Only remove our own entry: the id may since have been reused.
        activeDownloads.remove(downloadId, state)
        if (partFile.exists()) partFile.delete()
        livePartFiles.remove(partFile.absolutePath)
      }
    }
  }

  // ─── Background (DownloadManager) tracking ──────────────────────────────────

  private fun runOnBgExecutor(task: () -> Unit) {
    try {
      bgExecutor.execute {
        try { task() } catch (_: Exception) {}
      }
    } catch (_: Exception) {} // RejectedExecutionException after invalidate
  }

  /** Starts the poller if it is not running. Call after adding to [bgDownloadIds]. */
  private fun ensureBackgroundPolling() {
    synchronized(bgExecutor) {
      if (bgPollFuture != null || bgExecutor.isShutdown) return
      bgPollFuture = bgExecutor.scheduleWithFixedDelay({
        try {
          // Stop when nothing is tracked. Checked under the lock so a download
          // added concurrently either sees the old future or restarts it.
          val idle = synchronized(bgExecutor) {
            if (bgDownloadIds.isEmpty()) {
              bgPollFuture?.cancel(false)
              bgPollFuture = null
              true
            } else false
          }
          if (!idle) pollBackgroundDownloads()
        } catch (_: Exception) {
          // An exception would silently cancel all future runs of this task.
        }
      }, 0L, 1500L, TimeUnit.MILLISECONDS)
    }
  }

  private fun pollBackgroundDownloads() {
    val tracked = bgDownloadIds.values.toSet()
    if (tracked.isEmpty()) return
    val dm = reactContext.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
    val query = DownloadManager.Query().setFilterById(*tracked.toLongArray())
    val cursor = dm.query(query) ?: return
    val seen = HashSet<Long>()
    val terminal = ArrayList<Long>()
    cursor.use { c ->
      if (c.moveToFirst()) {
        val idIdx = c.getColumnIndex(DownloadManager.COLUMN_ID)
        val statusIdx = c.getColumnIndex(DownloadManager.COLUMN_STATUS)
        val totalIdx = c.getColumnIndex(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)
        val currentIdx = c.getColumnIndex(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)
        val uriIdx = c.getColumnIndex(DownloadManager.COLUMN_URI)
        do {
          val bgId = c.getLong(idIdx)
          seen.add(bgId)
          val status = c.getInt(statusIdx)
          if (status == DownloadManager.STATUS_SUCCESSFUL || status == DownloadManager.STATUS_FAILED) {
            terminal.add(bgId)
            continue
          }
          val downloadId = downloadIdForBgId(bgId) ?: continue
          val total = c.getLong(totalIdx)
          val current = c.getLong(currentIdx)
          if (status == DownloadManager.STATUS_RUNNING || status == DownloadManager.STATUS_PENDING) {
            val progress = if (total > 0) (current * 100 / total).toInt() else 0
            val uriString = c.getString(uriIdx) ?: ""
            val evt = Arguments.createMap().apply {
              putString("url", uriString)
              putString("downloadId", downloadId)
              putInt("progress", progress)
              putDouble("bytesDownloaded", current.toDouble())
              putDouble("totalBytes", total.toDouble())
            }
            emit("onDownloadProgress", evt)
          }
        } while (c.moveToNext())
      }
    }
    // Finished (possibly while the process was dead, so the broadcast was
    // missed) or removed from DownloadManager by the user.
    terminal.forEach { finalizeBackground(it) }
    tracked.filter { it !in seen }.forEach { finalizeBackground(it) }
  }

  /**
   * Reports the outcome of a background download exactly once and stops
   * tracking it. Called (on [bgExecutor]) by both the completion receiver and
   * the poller; anything that is not a terminal status is ignored, so a forged
   * or early ACTION_DOWNLOAD_COMPLETE cannot end a running download.
   */
  private fun finalizeBackground(bgId: Long) {
    val downloadId = bgDownloadIds.entries.firstOrNull { it.value == bgId }?.key ?: return
    val dm = reactContext.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
    var status = -1
    var localUri: String? = null
    var reason = 0
    var found = false
    dm.query(DownloadManager.Query().setFilterById(bgId))?.use { c ->
      if (c.moveToFirst()) {
        found = true
        status = c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
        localUri = c.getString(c.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI))
        reason = c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON))
      }
    } ?: return // Query failed: leave it tracked and try again on the next poll.
    if (found && status != DownloadManager.STATUS_SUCCESSFUL && status != DownloadManager.STATUS_FAILED) return

    val checksum = bgPrefs.getString("$bgId.checksum", null)
    // Atomic claim — loses against cancelDownload or an earlier finalisation.
    if (!forgetBackgroundDownload(downloadId, bgId)) return

    if (!found) {
      emit("onDownloadError", Arguments.createMap().apply {
        putBoolean("success", false)
        putString("downloadId", downloadId)
        putString("error", "DownloadManager entry was removed")
      }, bufferUntilSubscribed = true)
      return
    }
    if (status == DownloadManager.STATUS_FAILED) {
      emit("onDownloadError", Arguments.createMap().apply {
        putBoolean("success", false)
        putString("downloadId", downloadId)
        putString("error", "DownloadManager failed with reason/code: $reason")
      }, bufferUntilSubscribed = true)
      return
    }

    // COLUMN_LOCAL_URI is a percent-encoded file:// URI; Uri.parse().path
    // decodes it, whereas trimming the scheme leaves "%20" in the path.
    val filePath = localUri?.let { uri -> Uri.parse(uri).path } ?: ""
    if (checksum != null) {
      val algorithm = checksum.substringBefore(':')
      val expectedHash = checksum.substringAfter(':')
      val error = try {
        val actualHash = calculateChecksum(File(filePath), algorithm)
        if (actualHash.equals(expectedHash, ignoreCase = true)) null
        else "CHECKSUM_MISMATCH: expected $expectedHash, got $actualHash"
      } catch (e: Exception) {
        e.message ?: "CHECKSUM_ERROR"
      }
      if (error != null) {
        File(filePath).delete()
        emit("onDownloadError", Arguments.createMap().apply {
          putBoolean("success", false)
          putString("downloadId", downloadId)
          putString("error", error)
        }, bufferUntilSubscribed = true)
        return
      }
    }
    emit("onDownloadComplete", Arguments.createMap().apply {
      putBoolean("success", true)
      putString("downloadId", downloadId)
      putString("filePath", filePath)
    }, bufferUntilSubscribed = true)
  }

  // ─── executeDownload (Foreground) ─────────────────────────────────────────────────────────

  override fun pauseDownload(downloadId: String, promise: Promise) {
    val state = activeDownloads[downloadId]
    if (state == null) {
      val reason = if (bgDownloadIds.containsKey(downloadId)) {
        // Android's DownloadManager exposes no pause/resume API.
        "Background downloads cannot be paused on Android. Use background: false to pause/resume, or cancelDownload() to stop it."
      } else {
        "Download not found"
      }
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", false); putString("error", reason)
      })
      return
    }
    state.paused = true
    // Abort a read blocked on a stalled socket; the thread keeps the partial.
    state.interrupt()
    promise.resolve(Arguments.createMap().apply { putBoolean("success", true) })
  }

  // ─── resumeDownload ────────────────────────────────────────────────────────

  override fun resumeDownload(downloadId: String, promise: Promise) {
    val state = activeDownloads[downloadId]
    if (state == null) {
      val reason = if (bgDownloadIds.containsKey(downloadId)) {
        "Background downloads cannot be paused or resumed on Android; the system keeps them running."
      } else {
        "Download not found or already finished"
      }
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", false); putString("error", reason)
      })
      return
    }
    state.paused = false
    promise.resolve(Arguments.createMap().apply { putBoolean("success", true) })
  }

  // ─── cancelDownload ────────────────────────────────────────────────────────

  override fun cancelDownload(downloadId: String, promise: Promise) {
    // Removed synchronously so the id can be reused as soon as this resolves;
    // the old thread only removes its own entry and deletes its own partial.
    val state = activeDownloads.remove(downloadId)
    if (state != null) {
      state.cancelled = true
      state.interrupt()
      if (state.claim(OUTCOME_CANCELLED)) {
        state.promise.resolve(cancelledResult(downloadId))
      } else if (state.result != OUTCOME_CANCELLED) {
        // The download committed (or failed) before the cancel arrived.
        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", false)
          putString("downloadId", downloadId)
          putString("error", "ALREADY_COMPLETED")
        })
        return
      }
    }
    // Also cancel background DownloadManager downloads
    val bgId = bgDownloadIds[downloadId]
    if (bgId != null) {
      if (!forgetBackgroundDownload(downloadId, bgId)) {
        // finalizeBackground won: JS has been (or is being) told the outcome, and
        // dm.remove() would delete the finished file.
        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", false)
          putString("downloadId", downloadId)
          putString("error", "ALREADY_COMPLETED")
        })
        return
      }
      try {
        val dm = reactContext.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        dm.remove(bgId)
      } catch (_: Exception) {}
    }
    promise.resolve(Arguments.createMap().apply { putBoolean("success", true) })
  }

  // ─── getCachedFiles ────────────────────────────────────────────────────────

  override fun getCachedFiles(promise: Promise) {
    try {
      val list = Arguments.createArray()

      // Scan only toolkit-owned subdirectories to avoid returning files from other apps
      for (dir in toolkitDirs()) {
        dir.listFiles()?.forEach { f ->
          if (!f.isFile || isPartialFile(f)) return@forEach
          list.pushMap(Arguments.createMap().apply {
            putString("fileName", f.name)
            putString("filePath", f.absolutePath)
            putDouble("size", f.length().toDouble())
            putDouble("modifiedAt", f.lastModified().toDouble())
          })
        }
      }

      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", true)
        putArray("files", list)
      })
    } catch (e: Exception) {
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", false); putString("error", e.message ?: "ERROR")
      })
    }
  }

  // ─── deleteFile ────────────────────────────────────────────────────────────

  override fun deleteFile(filePath: String, promise: Promise) {
    try {
      val file = File(filePath)
      if (!file.exists()) {
        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", false)
          putString("error", "File not found: $filePath")
        })
        return
      }
      // Match iOS (`removeItemAtPath:`), which removes directories recursively.
      val deleted = if (file.isDirectory) file.deleteRecursively() else file.delete()
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", deleted)
        if (!deleted) putString("error", "Could not delete: $filePath")
      })
    } catch (e: Throwable) {
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", false)
        putString("error", e.message ?: "DELETE_FILE_ERROR")
      })
    }
  }

  // ─── clearCache ────────────────────────────────────────────────────────────

  override fun clearCache(promise: Promise) {
    try {
      // Only clear the toolkit-owned cache/documents subdirectories — never the
      // app's own files, and never the downloads directory the user asked for.
      val downloadsDir = getDestinationDir("downloads").absolutePath
      val dirs = toolkitDirs().filter { it.absolutePath != downloadsDir }
      for (dir in dirs) {
        // Skip partial files of running downloads: deleting one would fail that
        // download at commit time.
        dir.listFiles()?.forEach { if (it.absolutePath !in livePartFiles) it.deleteRecursively() }
      }
      promise.resolve(Arguments.createMap().apply { putBoolean("success", true) })
    } catch (e: Exception) {
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", false); putString("error", e.message ?: "ERROR")
      })
    }
  }

  // ─── exists ────────────────────────────────────────────────────────────────

  override fun exists(filePath: String, promise: Promise) {
    try {
      val file = File(filePath)
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", true)
        putBoolean("exists", file.exists())
      })
    } catch (e: Throwable) {
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", false)
        putString("error", e.message ?: "EXISTS_ERROR")
      })
    }
  }

  // ─── stat ──────────────────────────────────────────────────────────────────

  override fun stat(filePath: String, promise: Promise) {
    try {
      val file = File(filePath)
      if (!file.exists()) {
        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", false)
          putString("error", "Path does not exist")
        })
        return
      }

      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", true)
        putMap("stat", Arguments.createMap().apply {
          putString("path", file.absolutePath)
          putString("name", file.name)
          putBoolean("isDir", file.isDirectory)
          putDouble("size", if (file.isFile) file.length().toDouble() else 0.0)
          putDouble("modified", file.lastModified().toDouble())
        })
      })
    } catch (e: Throwable) {
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", false)
        putString("error", e.message ?: "STAT_ERROR")
      })
    }
  }

  // ─── readFile ──────────────────────────────────────────────────────────────

  override fun readFile(filePath: String, encoding: String, promise: Promise) {
    try {
      val file = File(filePath)
      if (!file.exists() || file.isDirectory) {
        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", false)
          putString("error", "File not found: $filePath")
        })
        return
      }

      // Safety check: reject files > 50MB to prevent crashing the RN bridge
      if (file.length() > 50L * 1024 * 1024) {
        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", false)
          putString("error", "File exceeds 50MB limit for readFile. Use streaming or base64 encoding for large files.")
        })
        return
      }

      val data = if (encoding.equals("base64", ignoreCase = true)) {
        android.util.Base64.encodeToString(file.readBytes(), android.util.Base64.NO_WRAP)
      } else {
        file.readText(Charsets.UTF_8)
      }

      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", true)
        putString("data", data)
      })
    } catch (e: Throwable) {
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", false)
        putString("error", e.message ?: "READ_FILE_ERROR")
      })
    }
  }

  // ─── writeFile ─────────────────────────────────────────────────────────────

  override fun writeFile(filePath: String, data: String, encoding: String, promise: Promise) {
    try {
      val file = File(filePath)
      file.parentFile?.mkdirs()

      if (encoding.equals("base64", ignoreCase = true)) {
        val bytes = android.util.Base64.decode(data, android.util.Base64.DEFAULT)
        file.writeBytes(bytes)
      } else {
        file.writeText(data, Charsets.UTF_8)
      }

      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", true)
      })
    } catch (e: Throwable) {
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", false)
        putString("error", e.message ?: "WRITE_FILE_ERROR")
      })
    }
  }

  // ─── copyFile ──────────────────────────────────────────────────────────────

  override fun copyFile(fromPath: String, toPath: String, promise: Promise) {
    try {
      val src = File(fromPath)
      if (!src.exists() || src.isDirectory) {
        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", false)
          putString("error", "Source file not found: $fromPath")
        })
        return
      }

      transferItem(src, File(toPath), move = false)

      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", true)
      })
    } catch (e: Throwable) {
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", false)
        putString("error", e.message ?: "COPY_FILE_ERROR")
      })
    }
  }

  // ─── moveFile ──────────────────────────────────────────────────────────────

  override fun moveFile(fromPath: String, toPath: String, promise: Promise) {
    try {
      val src = File(fromPath)
      if (!src.exists()) {
        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", false)
          putString("error", "Source path not found: $fromPath")
        })
        return
      }

      transferItem(src, File(toPath), move = true)

      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", true)
      })
    } catch (e: Throwable) {
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", false)
        putString("error", e.message ?: "MOVE_FILE_ERROR")
      })
    }
  }

  /**
   * Copies or moves [src] to [dst] without losing data on failure. A copy is
   * staged next to [dst] and renamed over it, so an existing destination
   * survives until the new one is complete. `File.copyTo(overwrite = true)`
   * deletes the target first, which destroyed the source when both were the
   * same file. An existing directory is never replaced (that wiped it).
   */
  private fun transferItem(src: File, dst: File, move: Boolean) {
    if (dst.exists()) {
      if (src.canonicalPath == dst.canonicalPath) return
      if (dst.isDirectory) throw IOException("Destination is a directory: ${dst.path}")
    }
    dst.parentFile?.mkdirs()
    if (move && src.renameTo(dst)) return // same filesystem: atomic
    // Cross-filesystem move, or a copy.
    val tmp = File(dst.absoluteFile.parentFile, ".${UUID.randomUUID()}.ftk-tmp")
    try {
      src.copyRecursively(tmp)
      if (!tmp.renameTo(dst)) throw IOException("Could not replace ${dst.path}")
    } catch (e: Throwable) {
      tmp.deleteRecursively()
      throw e
    }
    if (move) src.deleteRecursively()
  }

  // ─── mkdir ─────────────────────────────────────────────────────────────────

  override fun mkdir(dirPath: String, promise: Promise) {
    try {
      val dir = File(dirPath)
      val ok = if (dir.exists()) dir.isDirectory else dir.mkdirs()
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", ok)
        if (!ok) putString("error", "Could not create directory: $dirPath")
      })
    } catch (e: Throwable) {
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", false)
        putString("error", e.message ?: "MKDIR_ERROR")
      })
    }
  }

  // ─── ls ────────────────────────────────────────────────────────────────────

  override fun ls(dirPath: String, promise: Promise) {
    try {
      val dir = File(dirPath)
      if (!dir.exists() || !dir.isDirectory) {
        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", false)
          putString("error", "Directory not found: $dirPath")
        })
        return
      }

      val entries = Arguments.createArray()
      dir.list()?.forEach { name -> entries.pushString(name) }

      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", true)
        putArray("entries", entries)
      })
    } catch (e: Throwable) {
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", false)
        putString("error", e.message ?: "LS_ERROR")
      })
    }
  }

  // ─── getBackgroundDownloads ──────────────────────────────────────────────────

  override fun getBackgroundDownloads(promise: Promise) {
    try {
      val dm = reactContext.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
      val query = DownloadManager.Query()
      // We check for all states that could still be in progress or completed but not yet handled
      val cursor = dm.query(query)
      val results = Arguments.createArray()

      cursor?.use { c ->
        if (c.moveToFirst()) {
          val idIdx = c.getColumnIndex(DownloadManager.COLUMN_ID)
          val statusIdx = c.getColumnIndex(DownloadManager.COLUMN_STATUS)
          val uriIdx = c.getColumnIndex(DownloadManager.COLUMN_URI)
          val totalIdx = c.getColumnIndex(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)
          val currentIdx = c.getColumnIndex(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)

          do {
            val downloadId = downloadIdForBgId(c.getLong(idIdx)) ?: continue
            val status = c.getInt(statusIdx)
            val total = c.getLong(totalIdx)
            val current = c.getLong(currentIdx)
            val progress = if (total > 0) (current * 100 / total).toInt() else 0

            results.pushMap(Arguments.createMap().apply {
              putString("downloadId", downloadId)
              putString("url", c.getString(uriIdx) ?: "")
              putInt("status", status)
              putInt("progress", progress)
            })
          } while (c.moveToNext())
        }
      }

      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", true)
        putArray("downloads", results)
      })
    } catch (e: Exception) {
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", false); putString("error", e.message ?: "ERROR")
      })
    }
  }

  // ─── upload ──────────────────────────────────────────────────────────────────

  override fun upload(options: ReadableMap, promise: Promise) {
    val urlString = options.getString("url")
    val filePath = options.getString("filePath")
    if (urlString.isNullOrBlank() || filePath.isNullOrBlank()) {
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", false); putString("error", "URL or filePath is missing")
      })
      return
    }

    val fieldName = if (options.hasKey("fieldName")) options.getString("fieldName") else "file"
    val uploadId = if (options.hasKey("uploadId")) options.getString("uploadId") else UUID.randomUUID().toString()
    val headersMap = options.getMap("headers")
    val paramsMap = options.getMap("parameters")

    thread {
      try {
        val file = File(filePath)
        if (!file.exists()) {
          promise.resolve(Arguments.createMap().apply {
            putBoolean("success", false); putString("error", "File not found")
          })
          return@thread
        }

        val boundary = "Boundary-${UUID.randomUUID()}"
        val lineEnd = "\r\n"
        val twoHyphens = "--"

        val url = URL(urlString)
        val connection = url.openConnection() as HttpURLConnection
        connection.doInput = true
        connection.doOutput = true
        connection.useCaches = false
        connection.requestMethod = "POST"
        connection.connectTimeout = connectTimeoutMs
        // Uploads can legitimately take a long time; only guard against a stalled socket.
        connection.readTimeout = readTimeoutMs
        connection.setRequestProperty("Connection", "Keep-Alive")
        connection.setRequestProperty("Content-Type", "multipart/form-data; boundary=$boundary")

        // Add custom headers
        headersMap?.toHashMap()?.forEach { (key, value) ->
          if (value is String) connection.setRequestProperty(key, value)
        }

        // Pre-calculate the exact body size so we can use fixed-length streaming.
        // Chunked transfer encoding (the old approach) is rejected by many upload
        // endpoints (e.g. S3 presigned URLs, Google Cloud Storage) with 411/400.
        val charset = Charsets.UTF_8
        var bodySize = 0L
        paramsMap?.toHashMap()?.forEach { (key, value) ->
          bodySize += (twoHyphens + boundary + lineEnd).toByteArray(charset).size
          bodySize += ("Content-Disposition: form-data; name=\"$key\"" + lineEnd).toByteArray(charset).size
          bodySize += ("Content-Type: text/plain; charset=UTF-8" + lineEnd + lineEnd).toByteArray(charset).size
          bodySize += (value.toString() + lineEnd).toByteArray(charset).size
        }
        bodySize += (twoHyphens + boundary + lineEnd).toByteArray(charset).size
        bodySize += ("Content-Disposition: form-data; name=\"$fieldName\"; filename=\"${file.name}\"" + lineEnd).toByteArray(charset).size
        bodySize += ("Content-Type: application/octet-stream" + lineEnd + lineEnd).toByteArray(charset).size
        bodySize += file.length()
        bodySize += lineEnd.toByteArray(charset).size
        bodySize += (twoHyphens + boundary + twoHyphens + lineEnd).toByteArray(charset).size

        connection.setFixedLengthStreamingMode(bodySize)

        val output = connection.outputStream
        val writer = output.bufferedWriter()

        // Add form parameters
        paramsMap?.toHashMap()?.forEach { (key, value) ->
          writer.write(twoHyphens + boundary + lineEnd)
          writer.write("Content-Disposition: form-data; name=\"$key\"" + lineEnd)
          writer.write("Content-Type: text/plain; charset=UTF-8" + lineEnd + lineEnd)
          writer.write(value.toString() + lineEnd)
        }

        // Add file
        writer.write(twoHyphens + boundary + lineEnd)
        writer.write("Content-Disposition: form-data; name=\"$fieldName\"; filename=\"${file.name}\"" + lineEnd)
        writer.write("Content-Type: application/octet-stream" + lineEnd + lineEnd)
        writer.flush()

        val fileInput = FileInputStream(file)
        val buffer = ByteArray(8192)
        var bytesRead: Int
        var totalUploaded = 0L
        val fileSize = file.length()
        var lastProgress = -1

        try {
          while (fileInput.read(buffer).also { bytesRead = it } != -1) {
            output.write(buffer, 0, bytesRead)
            totalUploaded += bytesRead

            if (fileSize > 0) {
              val progress = (totalUploaded * 100 / fileSize).toInt()
              if (progress > lastProgress) {
                lastProgress = progress
                val evt = Arguments.createMap().apply {
                  putString("url", urlString)
                  putString("uploadId", uploadId)
                  putInt("progress", progress)
                }
                emit("onUploadProgress", evt)
              }
            }
          }
          output.flush()
          writer.write(lineEnd)
          writer.write(twoHyphens + boundary + twoHyphens + lineEnd)
          writer.flush()
        } finally {
          // Guarantee streams are closed even if an exception is thrown while writing.
          try { writer.close() } catch (_: Exception) {}
          try { fileInput.close() } catch (_: Exception) {}
        }

        val responseCode: Int
        val responseBody: String
        try {
          responseCode = connection.responseCode
          responseBody = if (responseCode in 200..299) {
            connection.inputStream.bufferedReader().use { it.readText() }
          } else {
            connection.errorStream?.bufferedReader()?.use { it.readText() } ?: ""
          }
        } finally {
          // Guarantee the connection is released even if reading the response throws.
          try { connection.disconnect() } catch (_: Exception) {}
        }

        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", responseCode in 200..299)
          putInt("status", responseCode)
          putString("data", responseBody)
          putString("uploadId", uploadId)
          if (responseCode !in 200..299) putString("error", "HTTP $responseCode")
        })

      } catch (e: Exception) {
        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", false)
          putString("error", e.message ?: "UPLOAD_ERROR")
          putString("uploadId", uploadId)
        })
      }
    }
  }

  // ─── saveBase64AsFile ──────────────────────────────────────────────────────

  override fun saveBase64AsFile(options: ReadableMap, promise: Promise) {
    try {
      val base64String = options.getString("base64Data")
      if (base64String.isNullOrBlank()) {
        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", false)
          putString("error", "base64Data is required")
        })
        return
      }

      val rawFileName = if (options.hasKey("fileName")) options.getString("fileName") else null
      val fileName = rawFileName ?: "base64_file_${System.currentTimeMillis()}"
      val destination = options.takeIf { it.hasKey("destination") }?.getString("destination")

      // Decode base64
      val decodedBytes = try {
        android.util.Base64.decode(base64String, android.util.Base64.DEFAULT)
      } catch (e: IllegalArgumentException) {
        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", false)
          putString("error", "Invalid base64 string: ${e.message}")
        })
        return
      }

      val destFile = getDestinationFile(fileName, destination)
      
      // Write to file
      FileOutputStream(destFile).use { fos ->
        fos.write(decodedBytes)
      }

      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", true)
        putString("filePath", destFile.absolutePath)
      })

    } catch (e: Throwable) {
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", false)
        putString("error", e.message ?: "BASE64_SAVE_ERROR")
      })
    }
  }

  // ─── urlToBase64 ───────────────────────────────────────────────────────────

  override fun urlToBase64(options: ReadableMap, promise: Promise) {
    thread {
      try {
        val urlString = options.getString("url")
        if (urlString.isNullOrBlank()) {
          promise.resolve(Arguments.createMap().apply {
            putBoolean("success", false)
            putString("error", "URL is required")
          })
          return@thread
        }

        val headersMap = options.getMap("headers")
        // Same helper as downloads: timeouts + cross-protocol (http→https) redirects.
        val connection = openDownloadConnection(urlString, headersMap, 0L)
        val maxBytes = 50L * 1024 * 1024
        val tooLarge = Arguments.createMap().apply {
          putBoolean("success", false)
          putString("error", "Response exceeds 50 MB limit for urlToBase64")
        }
        val mimeType: String
        val bytes: ByteArray
        try {
          val responseCode = connection.responseCode
          if (responseCode !in 200..299) {
            promise.resolve(Arguments.createMap().apply {
              putBoolean("success", false)
              putString("error", "HTTP $responseCode")
            })
            return@thread
          }

          // Get MIME type from response
          mimeType = connection.contentType?.split(";")?.get(0)?.trim() ?: "application/octet-stream"

          // Cap at 50 MB to match readFile limit and prevent OOM. Checked up front
          // when the size is declared, and while streaming for chunked responses.
          val contentLength = connection.getHeaderField("Content-Length")?.toLongOrNull() ?: -1L
          if (contentLength > maxBytes) {
            promise.resolve(tooLarge)
            return@thread
          }
          val out = ByteArrayOutputStream(if (contentLength > 0) contentLength.toInt() else 64 * 1024)
          connection.inputStream.use { input ->
            val buffer = ByteArray(8192)
            var total = 0L
            while (true) {
              val count = input.read(buffer)
              if (count == -1) break
              total += count
              if (total > maxBytes) {
                promise.resolve(tooLarge)
                return@thread
              }
              out.write(buffer, 0, count)
            }
          }
          bytes = out.toByteArray()
        } finally {
          connection.disconnect()
        }

        // Encode to base64
        val base64String = android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)

        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", true)
          putString("base64", base64String)
          putString("mimeType", mimeType)
          putString("dataUri", "data:$mimeType;base64,$base64String")
        })

      } catch (e: Throwable) {
        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", false)
          putString("error", e.message ?: "URL_TO_BASE64_ERROR")
        })
      }
    }
  }

  // ─── shareFile ─────────────────────────────────────────────────────────────

  override fun shareFile(filePath: String, options: ReadableMap, promise: Promise) {
    try {
      val file = File(filePath)
      if (!file.exists()) {
        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", false)
          putString("error", "File not found: $filePath")
        })
        return
      }

      // Use the unique authority registered in AndroidManifest.xml (Fix #17)
      val authority = "${reactContext.packageName}.rn_file_toolkit.provider"
      val contentUri = FileProvider.getUriForFile(reactContext, authority, file)

      val shareIntent = Intent(Intent.ACTION_SEND).apply {
        type = getMimeType(filePath)
        putExtra(Intent.EXTRA_STREAM, contentUri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        
        // Optional title and subject from options
        if (options.hasKey("title")) {
          putExtra(Intent.EXTRA_TITLE, options.getString("title"))
        }
        if (options.hasKey("subject")) {
          putExtra(Intent.EXTRA_SUBJECT, options.getString("subject"))
        }
      }

      val chooserIntent = Intent.createChooser(shareIntent, "Share File")
      chooserIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      
      reactContext.startActivity(chooserIntent)

      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", true)
      })

    } catch (e: Exception) {
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", false)
        putString("error", e.message ?: "SHARE_ERROR")
      })
    }
  }

  // ─── openFile ──────────────────────────────────────────────────────────────

  override fun openFile(filePath: String, mimeType: String, promise: Promise) {
    try {
      val file = File(filePath)
      if (!file.exists()) {
        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", false)
          putString("error", "File not found: $filePath")
        })
        return
      }

      // Use the unique authority registered in AndroidManifest.xml (Fix #17)
      val authority = "${reactContext.packageName}.rn_file_toolkit.provider"
      val contentUri = FileProvider.getUriForFile(reactContext, authority, file)

      val detectedMimeType = if (mimeType.isNotBlank()) mimeType else getMimeType(filePath)

      val openIntent = Intent(Intent.ACTION_VIEW).apply {
        setDataAndType(contentUri, detectedMimeType)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      }

      // No resolveActivity() pre-check: on Android 11+ package visibility makes
      // it return null for most viewers unless the app declares <queries>.
      try {
        reactContext.startActivity(openIntent)
      } catch (_: ActivityNotFoundException) {
        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", false)
          putString("error", "No app found to open this file type: $detectedMimeType")
        })
        return
      }
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", true)
      })

    } catch (e: Exception) {
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", false)
        putString("error", e.message ?: "OPEN_FILE_ERROR")
      })
    }
  }

  // ─── Helper: Get MIME type ─────────────────────────────────────────────────

  private fun getMimeType(filePath: String): String {
    val extension = filePath.substringAfterLast('.', "")
    return if (extension.isNotBlank()) {
      MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension.lowercase()) ?: "application/octet-stream"
    } else {
      "application/octet-stream"
    }
  }

  // ─── Unzip ─────────────────────────────────────────────────────────────────

  override fun unzip(sourcePath: String, destDir: String, promise: Promise) {
    thread {
      // Everything this call creates, so a failure midway can be rolled back
      // without touching anything that existed before (matches iOS).
      val createdFiles = ArrayList<File>()
      val createdDirs = ArrayList<File>() // in creation order, outermost first
      var tempFile: File? = null

      fun mkdirsTracked(dir: File) {
        val missing = ArrayList<File>()
        var d: File? = dir
        while (d != null && !d.exists()) {
          missing.add(0, d)
          d = d.parentFile
        }
        for (m in missing) {
          if (m.mkdir()) createdDirs.add(m)
          else if (!m.isDirectory) throw java.io.IOException("Could not create directory: ${m.absolutePath}")
        }
      }

      try {
        val sourceFile = File(sourcePath)
        if (!sourceFile.exists()) {
          promise.resolve(Arguments.createMap().apply {
            putBoolean("success", false)
            putString("error", "Source zip file does not exist: $sourcePath")
          })
          return@thread
        }

        val destDirFile = File(destDir)
        val extractedFiles = Arguments.createArray()

        // ZipFile reads the authoritative central directory, so a truncated or
        // non-zip source fails here with a ZipException (ZipInputStream treated
        // truncation at an entry boundary as a clean end, and rejects STORED
        // entries with data descriptors). Unsupported compression methods and
        // truncated entry data throw from getInputStream()/read().
        java.util.zip.ZipFile(sourceFile).use { zip ->
          mkdirsTracked(destDirFile)
          val canonicalDest = destDirFile.canonicalPath
          for (entry in zip.entries()) {
            // Prevent zip-slip attacks
            val entryFile = File(destDirFile, entry.name)
            val canonicalEntry = entryFile.canonicalPath
            if (!canonicalEntry.startsWith(canonicalDest + File.separator) &&
                canonicalEntry != canonicalDest) {
              // Refuse to extract entries that escape the destination directory
              // (zip-slip attack). Return an error instead of silently skipping
              // to match iOS behaviour and prevent partial extractions.
              throw SecurityException("ZIP entry has invalid path: ${entry.name}")
            }

            if (entry.isDirectory) {
              mkdirsTracked(entryFile)
            } else {
              val parent = entryFile.parentFile ?: destDirFile
              mkdirsTracked(parent)
              // Write to a temp file and rename on success, so a failure midway
              // never leaves a pre-existing file half-overwritten.
              val existed = entryFile.exists()
              val tmp = File(parent, ".${entryFile.name.take(64)}.${UUID.randomUUID()}.unzip")
              tempFile = tmp
              // ZipFile does not verify CRCs (ZipInputStream did), so check here.
              val crc = java.util.zip.CRC32()
              val written = java.util.zip.CheckedInputStream(zip.getInputStream(entry), crc).use { input ->
                FileOutputStream(tmp).buffered().use { fos -> input.copyTo(fos) }
              }
              if ((entry.size >= 0 && written != entry.size) || (entry.crc >= 0 && crc.value != entry.crc)) {
                throw java.util.zip.ZipException("ZIP entry is corrupt: ${entry.name}")
              }
              if (!tmp.renameTo(entryFile)) {
                throw java.io.IOException("Could not write ${entryFile.absolutePath}")
              }
              tempFile = null
              if (!existed) createdFiles.add(entryFile)
              extractedFiles.pushString(entryFile.absolutePath)
            }
          }
        }

        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", true)
          putString("destDir", destDirFile.absolutePath)
          putArray("files", extractedFiles)
        })
      } catch (e: Exception) {
        // Roll back: files first, then directories innermost-first. File.delete()
        // on a directory only succeeds when empty, so foreign content survives.
        tempFile?.delete()
        createdFiles.asReversed().forEach { it.delete() }
        createdDirs.asReversed().forEach { it.delete() }
        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", false)
          putString("error", e.message ?: "UNZIP_ERROR")
        })
      }
    }
  }

  // ─── Zip ───────────────────────────────────────────────────────────────────

  override fun zip(sourcePath: String, destPath: String, promise: Promise) {
    thread {
      try {
        val sourceFile = File(sourcePath)
        if (!sourceFile.exists()) {
          promise.resolve(Arguments.createMap().apply {
            putBoolean("success", false)
            putString("error", "Source path does not exist: $sourcePath")
          })
          return@thread
        }

        val destFile = File(destPath)
        val destCanonical = destFile.canonicalPath
        if (sourceFile.isFile && sourceFile.canonicalPath == destCanonical) {
          promise.resolve(Arguments.createMap().apply {
            putBoolean("success", false)
            putString("error", "Destination path must differ from the source")
          })
          return@thread
        }
        destFile.parentFile?.mkdirs()
        destFile.delete()

        ZipOutputStream(FileOutputStream(destFile).buffered()).use { zos ->
          if (sourceFile.isDirectory) {
            zipDirectory(sourceFile, sourceFile.name, zos, destCanonical)
          } else {
            zipFile(sourceFile, sourceFile.name, zos)
          }
        }

        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", true)
          putString("zipPath", destFile.absolutePath)
        })
      } catch (e: Exception) {
        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", false)
          putString("error", e.message ?: "ZIP_ERROR")
        })
      }
    }
  }

  /** [skipPath]: the archive being written, which may live inside [dir]. */
  private fun zipDirectory(dir: File, baseName: String, zos: ZipOutputStream, skipPath: String) {
    val files = dir.listFiles() ?: return
    if (files.isEmpty()) {
      // Add empty directory entry
      zos.putNextEntry(ZipEntry("$baseName/"))
      zos.closeEntry()
      return
    }
    for (file in files) {
      val entryName = "$baseName/${file.name}"
      if (file.isDirectory) {
        zipDirectory(file, entryName, zos, skipPath)
      } else if (file.canonicalPath != skipPath) {
        zipFile(file, entryName, zos)
      }
    }
  }

  private fun zipFile(file: File, entryName: String, zos: ZipOutputStream) {
    zos.putNextEntry(ZipEntry(entryName))
    FileInputStream(file).buffered().use { fis ->
      fis.copyTo(zos)
    }
    zos.closeEntry()
  }

  // ─── df (disk space) ──────────────────────────────────────────────────────

  override fun df(promise: Promise) {
    try {
      val stat = android.os.StatFs(Environment.getDataDirectory().path)
      val freeBytes = stat.availableBytes
      val totalBytes = stat.totalBytes

      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", true)
        putDouble("freeBytes", freeBytes.toDouble())
        putDouble("totalBytes", totalBytes.toDouble())
      })
    } catch (e: Throwable) {
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", false)
        putString("error", e.message ?: "DF_ERROR")
      })
    }
  }

  // ─── appendFile ───────────────────────────────────────────────────────────

  override fun appendFile(filePath: String, data: String, encoding: String, promise: Promise) {
    try {
      val file = File(filePath)
      if (!file.exists()) {
        // Create parent dirs and the file if it doesn't exist
        file.parentFile?.mkdirs()
      }

      if (encoding.equals("base64", ignoreCase = true)) {
        val bytes = android.util.Base64.decode(data, android.util.Base64.DEFAULT)
        FileOutputStream(file, true).use { fos ->
          fos.write(bytes)
        }
      } else {
        FileOutputStream(file, true).use { fos ->
          fos.write(data.toByteArray(Charsets.UTF_8))
        }
      }

      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", true)
      })
    } catch (e: Throwable) {
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", false)
        putString("error", e.message ?: "APPEND_FILE_ERROR")
      })
    }
  }

  // ─── hash ─────────────────────────────────────────────────────────────────

  override fun hash(filePath: String, algorithm: String, promise: Promise) {
    try {
      val file = File(filePath)
      if (!file.exists() || file.isDirectory) {
        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", false)
          putString("error", "File not found: $filePath")
        })
        return
      }

      val hashValue = calculateChecksum(file, algorithm)

      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", true)
        putString("hash", hashValue)
      })
    } catch (e: Throwable) {
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", false)
        putString("error", e.message ?: "HASH_ERROR")
      })
    }
  }

  // ─── getCookies ───────────────────────────────────────────────────────────

  /**
   * Android's [android.webkit.CookieManager] keys cookies by URL, not by bare
   * host: `getCookie("example.com")` always returns null. Callers naturally pass
   * a domain (that is what the API is named after and what iOS accepts), so
   * normalise it to a URL here.
   */
  private fun cookieUrlFor(domain: String): String {
    if (domain.isBlank()) return domain
    return if (domain.startsWith("http://") || domain.startsWith("https://")) {
      domain
    } else {
      "https://${domain.trimStart('.')}"
    }
  }

  override fun getCookies(domain: String, promise: Promise) {
    try {
      val cookieManager = android.webkit.CookieManager.getInstance()
      val cookieString = cookieManager.getCookie(cookieUrlFor(domain))

      val cookiesArray = Arguments.createArray()

      if (!cookieString.isNullOrBlank()) {
        // CookieManager returns cookies as "name1=value1; name2=value2; ..."
        cookieString.split(";").forEach { pair ->
          val trimmed = pair.trim()
          val eqIndex = trimmed.indexOf("=")
          if (eqIndex > 0) {
            val name = trimmed.substring(0, eqIndex)
            val value = trimmed.substring(eqIndex + 1)
            cookiesArray.pushMap(Arguments.createMap().apply {
              putString("name", name)
              putString("value", value)
              putString("domain", domain)
              putString("path", "/")
            })
          }
        }
      }

      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", true)
        putArray("cookies", cookiesArray)
      })
    } catch (e: Throwable) {
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", false)
        putString("error", e.message ?: "GET_COOKIES_ERROR")
      })
    }
  }

  // ─── clearCookies ─────────────────────────────────────────────────────────

  override fun clearCookies(domain: String, promise: Promise) {
    try {
      val cookieManager = android.webkit.CookieManager.getInstance()

      if (domain.isBlank()) {
        // Clear ALL cookies
        cookieManager.removeAllCookies { success ->
          promise.resolve(Arguments.createMap().apply {
            putBoolean("success", success)
          })
        }
      } else {
        // Android CookieManager does not support per-domain clearing directly.
        // We read cookies for the domain and overwrite each with an expired one.
        // A cookie is keyed by (name, domain, path) and getCookie() reports only
        // names, so expire every variant it could have been set with: host-only
        // and Domain= for the host and each parent domain, at Path=/ and at each
        // prefix of the URL's path.
        val cookieUrl = cookieUrlFor(domain)
        val cookieString = cookieManager.getCookie(cookieUrl)
        if (!cookieString.isNullOrBlank()) {
          val parsed = Uri.parse(cookieUrl)
          val host = parsed.host ?: domain.trimStart('.')
          val isIp = host.contains(':') || host.matches(Regex("""\d{1,3}(\.\d{1,3}){3}"""))
          val labels = host.split('.')
          // "a.b.example.com" → a.b.example.com, b.example.com, example.com (never the bare TLD)
          val domains = if (isIp) listOf(host) else (0 until maxOf(labels.size - 1, 1)).map {
            labels.drop(it).joinToString(".")
          }
          val paths = mutableListOf("/")
          parsed.pathSegments.fold("") { prefix, segment ->
            ("$prefix/$segment").also { paths.add(it) }
          }
          // Overwriting a Secure (or __Secure-/__Host-) cookie needs Secure, which
          // is only accepted from an https URL.
          val secure = if (cookieUrl.startsWith("https://")) "; Secure" else ""
          val expired = "Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=0"
          cookieString.split(";").forEach { pair ->
            val trimmed = pair.trim()
            val eqIndex = trimmed.indexOf("=")
            if (eqIndex > 0) {
              val name = trimmed.substring(0, eqIndex)
              for (path in paths) {
                cookieManager.setCookie(cookieUrl, "$name=; $expired; Path=$path$secure")
                for (d in domains) {
                  cookieManager.setCookie(cookieUrl, "$name=; $expired; Domain=$d; Path=$path$secure")
                }
              }
            }
          }
          cookieManager.flush()
        }
        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", true)
        })
      }
    } catch (e: Throwable) {
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", false)
        putString("error", e.message ?: "CLEAR_COOKIES_ERROR")
      })
    }
  }

  // ─── saveToMediaStore ─────────────────────────────────────────────────────

  override fun saveToMediaStore(options: ReadableMap, promise: Promise) {
    val filePath = options.getString("filePath")
    if (filePath.isNullOrBlank()) {
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", false)
        putString("error", "filePath is required")
      })
      return
    }

    val mediaType = if (options.hasKey("mediaType")) options.getString("mediaType") else "download"
    val album = if (options.hasKey("album")) options.getString("album") else null

    thread {
      try {
        val file = File(filePath)
        if (!file.exists()) {
          promise.resolve(Arguments.createMap().apply {
            putBoolean("success", false)
            putString("error", "File not found: $filePath")
          })
          return@thread
        }

        val mimeType = getMimeType(filePath)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
          // Android 10+ — use MediaStore ContentResolver API
          val contentUri = when (mediaType) {
            "image" -> android.provider.MediaStore.Images.Media.getContentUri(android.provider.MediaStore.VOLUME_EXTERNAL_PRIMARY)
            "video" -> android.provider.MediaStore.Video.Media.getContentUri(android.provider.MediaStore.VOLUME_EXTERNAL_PRIMARY)
            "audio" -> android.provider.MediaStore.Audio.Media.getContentUri(android.provider.MediaStore.VOLUME_EXTERNAL_PRIMARY)
            else -> android.provider.MediaStore.Downloads.getContentUri(android.provider.MediaStore.VOLUME_EXTERNAL_PRIMARY)
          }

          val relativePath = when (mediaType) {
            "image" -> if (album != null) "${Environment.DIRECTORY_PICTURES}/$album" else Environment.DIRECTORY_PICTURES
            "video" -> if (album != null) "${Environment.DIRECTORY_MOVIES}/$album" else Environment.DIRECTORY_MOVIES
            "audio" -> if (album != null) "${Environment.DIRECTORY_MUSIC}/$album" else Environment.DIRECTORY_MUSIC
            else -> if (album != null) "${Environment.DIRECTORY_DOWNLOADS}/$album" else Environment.DIRECTORY_DOWNLOADS
          }

          val values = android.content.ContentValues().apply {
            put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, file.name)
            put(android.provider.MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(android.provider.MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            put(android.provider.MediaStore.MediaColumns.IS_PENDING, 1)
          }

          val resolver = reactContext.contentResolver
          val uri = resolver.insert(contentUri, values)

          if (uri == null) {
            promise.resolve(Arguments.createMap().apply {
              putBoolean("success", false)
              putString("error", "Failed to create MediaStore entry")
            })
            return@thread
          }

          // Never leave a half-written, IS_PENDING row behind on failure.
          try {
            val outputStream = resolver.openOutputStream(uri)
            if (outputStream == null) {
              try { resolver.delete(uri, null, null) } catch (_: Exception) {}
              promise.resolve(Arguments.createMap().apply {
                putBoolean("success", false)
                putString("error", "Failed to open MediaStore entry for writing")
              })
              return@thread
            }
            outputStream.use { os ->
              FileInputStream(file).use { inputStream -> inputStream.copyTo(os, 8192) }
            }
            values.clear()
            values.put(android.provider.MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
          } catch (e: Exception) {
            try { resolver.delete(uri, null, null) } catch (_: Exception) {}
            throw e
          }

          promise.resolve(Arguments.createMap().apply {
            putBoolean("success", true)
            putString("uri", uri.toString())
          })
        } else {
          // Android 9 and below — copy to public directory and media-scan.
          // Needs WRITE_EXTERNAL_STORAGE, which the host app must declare and
          // request (not declared here: it would clash with the Expo plugin's
          // maxSdkVersion during manifest merging).
          if (ContextCompat.checkSelfPermission(reactContext, android.Manifest.permission.WRITE_EXTERNAL_STORAGE)
            != PackageManager.PERMISSION_GRANTED) {
            promise.resolve(Arguments.createMap().apply {
              putBoolean("success", false)
              putString("error", "WRITE_EXTERNAL_STORAGE permission is required on Android 9 and below")
            })
            return@thread
          }
          val destDir = when (mediaType) {
            "image" -> Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES)
            "video" -> Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES)
            "audio" -> Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC)
            else -> Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
          }

          val albumDir = if (album != null) File(destDir, album) else destDir
          albumDir.mkdirs()
          val destFile = File(albumDir, file.name)
          transferItem(file, destFile, move = false)

          android.media.MediaScannerConnection.scanFile(
            reactContext,
            arrayOf(destFile.absolutePath),
            arrayOf(mimeType)
          ) { _, scannedUri ->
            promise.resolve(Arguments.createMap().apply {
              putBoolean("success", true)
              putString("uri", scannedUri?.toString() ?: destFile.absolutePath)
            })
          }
        }
      } catch (e: Exception) {
        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", false)
          putString("error", e.message ?: "MEDIA_STORE_ERROR")
        })
      }
    }
  }

  companion object {
    const val NAME = NativeFileToolkitSpec.NAME
    /** Same limit as the platform's own redirect follower. */
    private const val MAX_REDIRECTS = 20
    private val CREDENTIAL_HEADERS = setOf("authorization", "cookie", "proxy-authorization")
  }
}

