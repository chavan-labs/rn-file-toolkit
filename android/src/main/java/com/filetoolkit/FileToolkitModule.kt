package com.filetoolkit

import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import androidx.core.content.FileProvider
import android.content.BroadcastReceiver
import android.content.IntentFilter
import android.database.Cursor
import android.os.Handler
import android.os.Looper
import android.os.Build
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.Arguments
import com.facebook.react.modules.core.DeviceEventManagerModule
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLDecoder
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream
import kotlin.concurrent.thread
import android.webkit.MimeTypeMap

// ─── Per-download state ───────────────────────────────────────────────────────

private data class DownloadState(
  val url: String,
  val fileName: String,
  val isBackground: Boolean,
  @Volatile var paused: Boolean = false,
  @Volatile var cancelled: Boolean = false,
  /** Bytes already written (for Range resume) */
  @Volatile var bytesDownloaded: Long = 0L
)

class FileToolkitModule(private val reactContext: ReactApplicationContext) :
  NativeFileToolkitSpec(reactContext) {

  // downloadId → state
  private val activeDownloads = ConcurrentHashMap<String, DownloadState>()
  // downloadId → background DownloadManager ID
  private val bgDownloadIds = ConcurrentHashMap<String, Long>()
  // Stored promises for foreground downloads — resolved on completion (not early)
  private val foregroundPromises = ConcurrentHashMap<String, Promise>()

  private val bgPollHandler = Handler(Looper.getMainLooper())
  private val bgPollRunnable = object : Runnable {
    override fun run() {
      if (bgDownloadIds.isNotEmpty()) {
        pollBackgroundDownloads()
        bgPollHandler.postDelayed(this, 1500)
      }
      // Stop polling when no background downloads remain
    }
  }

  private val downloadReceiver = object : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
      if (intent?.action == DownloadManager.ACTION_DOWNLOAD_COMPLETE) {
        val id = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1L)
        handleBackgroundDownloadComplete(id)
      }
    }
  }

  /**
   * Persistent DownloadManager id → toolkit downloadId mapping.
   *
   * Background downloads outlive the process, so the mapping cannot live only in
   * memory. It also must not live in the notification description: callers can
   * override that via `notificationDescription`, which used to silently break
   * every progress/complete event for the download.
   */
  private val bgPrefs by lazy {
    reactContext.getSharedPreferences("rn_file_toolkit_bg", Context.MODE_PRIVATE)
  }

  private fun rememberBackgroundDownload(downloadId: String, bgId: Long) {
    bgDownloadIds[downloadId] = bgId
    bgPrefs.edit().putString(bgId.toString(), downloadId).apply()
  }

  private fun forgetBackgroundDownload(downloadId: String, bgId: Long) {
    bgDownloadIds.remove(downloadId)
    bgPrefs.edit().remove(bgId.toString()).apply()
  }

  /** Resolves a DownloadManager id back to the toolkit downloadId, or null. */
  private fun downloadIdForBgId(bgId: Long): String? {
    bgDownloadIds.entries.firstOrNull { it.value == bgId }?.let { return it.key }
    return bgPrefs.getString(bgId.toString(), null)
  }

  init {
    // Re-adopt downloads started before the process was killed.
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
  }

  override fun invalidate() {
    super.invalidate()
    try {
      reactContext.unregisterReceiver(downloadReceiver)
    } catch (_: Exception) {} // Receiver may not be registered
    bgPollHandler.removeCallbacks(bgPollRunnable)
    // Stop foreground download threads and settle their promises, otherwise a dev
    // reload leaves orphaned threads writing files for a bridge that is gone.
    activeDownloads.values.forEach { it.cancelled = true }
    activeDownloads.clear()
    foregroundPromises.keys.toList().forEach { id ->
      foregroundPromises.remove(id)?.resolve(Arguments.createMap().apply {
        putBoolean("success", false)
        putString("downloadId", id)
        putString("error", "CANCELLED")
      })
    }
  }

  override fun addListener(eventName: String?) {
    // No-op - Required by React Native NativeEventEmitter
  }

  override fun removeListeners(count: Double) {
    // No-op - Required by React Native NativeEventEmitter
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────

  private fun emit(event: String, map: com.facebook.react.bridge.WritableMap) {
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
   */
  private fun openDownloadConnection(
    urlString: String,
    headersMap: ReadableMap?,
    resumeFrom: Long
  ): HttpURLConnection {
    var currentUrl = URL(urlString)
    var redirects = 0
    while (true) {
      val connection = currentUrl.openConnection() as HttpURLConnection
      connection.connectTimeout = connectTimeoutMs
      connection.readTimeout = readTimeoutMs
      connection.instanceFollowRedirects = true
      // Ask for an unencoded body: HttpURLConnection transparently gunzips a
      // gzipped response but still reports the *compressed* Content-Length,
      // which makes progress percentages run past 100%.
      connection.setRequestProperty("Accept-Encoding", "identity")

      headersMap?.toHashMap()?.forEach { (key, value) ->
        if (value is String) connection.setRequestProperty(key, value)
      }
      if (resumeFrom > 0) {
        connection.setRequestProperty("Range", "bytes=$resumeFrom-")
      }
      connection.connect()

      val code = connection.responseCode
      val isRedirect = code == HttpURLConnection.HTTP_MOVED_PERM ||
        code == HttpURLConnection.HTTP_MOVED_TEMP ||
        code == HttpURLConnection.HTTP_SEE_OTHER ||
        code == 307 || code == 308
      val location = connection.getHeaderField("Location")
      if (!isRedirect || location == null || redirects >= 5) return connection

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
    val retryMap = options.takeIf { it.hasKey("retry") }?.getMap("retry")
    val maxAttempts = retryMap?.takeIf { it.hasKey("attempts") }?.getInt("attempts") ?: 0
    val baseDelay = retryMap?.takeIf { it.hasKey("delay") }?.getInt("delay") ?: 1000

    val state = DownloadState(url = urlString, fileName = fileName, isBackground = isBackground)
    // Only add foreground downloads to activeDownloads — the state object is used
    // exclusively by the foreground pause/cancel logic.  Background downloads are
    // managed through bgDownloadIds / DownloadManager; adding them here created a
    // race window where cancelDownload could see the state but not yet the bgId.
    if (!isBackground) {
      activeDownloads[downloadId] = state
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
        val bgId = dm.enqueue(request)
        rememberBackgroundDownload(downloadId, bgId)
        activeDownloads.remove(downloadId)

        // Start polling if not running
        bgPollHandler.removeCallbacks(bgPollRunnable)
        bgPollHandler.post(bgPollRunnable)

        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", true)
          putString("downloadId", downloadId)
        })
      } catch (e: Exception) {
        // DownloadManager rejects unsupported schemes (file://, data:) and can be
        // disabled by the user, both of which throw rather than returning an id.
        activeDownloads.remove(downloadId)
        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", false)
          putString("downloadId", downloadId)
          putString("error", e.message ?: "DOWNLOAD_MANAGER_ERROR")
        })
      }
      return
    }

    // Foreground: store promise — resolve on completion (matches iOS behaviour)
    foregroundPromises[downloadId] = promise

    thread {
      var attempt = 0
      var lastError = "NETWORK_ERROR"

      retryLoop@ while (true) {
        // ── Before retry: emit event + wait with exponential backoff ───────
        if (attempt > 0) {
          state.bytesDownloaded = 0L          // fresh download on retry
          getDestinationFile(fileName, destination).delete() // Fix #5: Delete corrupted partial file

          val delayMs = (baseDelay.toLong() * (1L shl (attempt - 1))).coerceAtMost(30_000L)
          // Bug #5 fix: emit retry event BEFORE the delay so JS callback fires immediately
          val retryEvt = Arguments.createMap().apply {
            putString("downloadId", downloadId)
            putString("url", urlString)
            putInt("attempt", attempt)
            putString("error", lastError)
          }
          emit("onDownloadRetry", retryEvt)
          // Interruptible retry delay — respects cancel and responds to pause
          val deadline = System.currentTimeMillis() + delayMs
          while (System.currentTimeMillis() < deadline) {
            if (state.cancelled) break
            Thread.sleep(minOf(deadline - System.currentTimeMillis(), 100L).coerceAtLeast(0L))
          }
          // Wait while paused (checked after the retry delay, also respects cancel)
          while (state.paused && !state.cancelled) {
            Thread.sleep(100L)
          }
        }

        try {
          val resumeFrom = state.bytesDownloaded
          val destFile = getDestinationFile(fileName, destination)

          val connection = openDownloadConnection(urlString, headersMap, resumeFrom)

          val responseCode = connection.responseCode
          if (responseCode != HttpURLConnection.HTTP_OK && responseCode != HttpURLConnection.HTTP_PARTIAL) {
            // Server error — do NOT retry (4xx/5xx are not transient)
            connection.disconnect()
            activeDownloads.remove(downloadId)
            foregroundPromises.remove(downloadId)?.resolve(Arguments.createMap().apply {
              putBoolean("success", false)
              putString("downloadId", downloadId)
              putString("error", "SERVER_ERROR: $responseCode")
            })
            emit("onDownloadError", Arguments.createMap().apply {
              putBoolean("success", false)
              putString("downloadId", downloadId)
              putString("error", "SERVER_ERROR: $responseCode")
            })
            return@thread
          }

          val contentLength = connection.getHeaderField("Content-Length")?.toLongOrNull() ?: -1L
          val totalExpected = if (resumeFrom > 0) resumeFrom + contentLength else contentLength

          // Bug #1 fix: always close streams via try-finally to prevent handle leaks between retries
          val input = connection.inputStream
          val output: FileOutputStream = if (resumeFrom > 0) {
            FileOutputStream(destFile, true) // append
          } else {
            FileOutputStream(destFile, false)
          }

          val buffer = ByteArray(8192)
          var total = resumeFrom
          var count: Int
          var lastProgress = -1

          try {
            while (input.read(buffer).also { count = it } != -1) {
              while (state.paused && !state.cancelled) {
                state.bytesDownloaded = total
                Thread.sleep(200)
              }
              if (state.cancelled) {
                output.flush(); output.close(); input.close()
                destFile.delete()
                activeDownloads.remove(downloadId)
                foregroundPromises.remove(downloadId)?.resolve(
                  Arguments.createMap().apply {
                    putBoolean("success", false)
                    putString("downloadId", downloadId)
                    putString("error", "CANCELLED")
                  }
                )
                return@thread
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
              }
            }
            output.flush()
          } finally {
            // Bug #1 fix: guaranteed close regardless of exception
            try { output.close() } catch (_: Exception) {}
            try { input.close() } catch (_: Exception) {}
            connection.disconnect()
          }

          activeDownloads.remove(downloadId)

          // ── Checksum verification ─────────────────────────────────────────
          if (checksumMap != null) {
            val expectedHash = checksumMap.getString("hash")
            val algorithm = checksumMap.getString("algorithm")?.uppercase() ?: "MD5"
            if (expectedHash != null) {
              val actualHash = calculateChecksum(destFile, algorithm)
              if (!actualHash.equals(expectedHash, ignoreCase = true)) {
                destFile.delete()
                foregroundPromises.remove(downloadId)?.resolve(Arguments.createMap().apply {
                  putBoolean("success", false)
                  putString("downloadId", downloadId)
                  putString("error", "CHECKSUM_MISMATCH: expected $expectedHash, got $actualHash")
                })
                emit("onDownloadError", Arguments.createMap().apply {
                  putBoolean("success", false)
                  putString("downloadId", downloadId)
                  putString("error", "CHECKSUM_MISMATCH: expected $expectedHash, got $actualHash")
                })
                return@thread
              }
            }
          }

          val resolvedPromise = foregroundPromises.remove(downloadId)
          resolvedPromise?.resolve(Arguments.createMap().apply {
            putBoolean("success", true)
            putString("downloadId", downloadId)
            putString("filePath", destFile.absolutePath)
          })
          // Only emit the event when there is no foreground promise (background-style usage),
          // matching iOS behaviour where onDownloadComplete fires only for background downloads.
          if (resolvedPromise == null) {
            emit("onDownloadComplete", Arguments.createMap().apply {
              putBoolean("success", true)
              putString("downloadId", downloadId)
              putString("filePath", destFile.absolutePath)
            })
          }
          break@retryLoop // ✅ success

        } catch (e: Exception) {
          lastError = e.message ?: "NETWORK_ERROR"   // Bug #3 fix: save error for next retry event
          if (state.cancelled) {
            activeDownloads.remove(downloadId)
            foregroundPromises.remove(downloadId)?.resolve(
              Arguments.createMap().apply {
                putBoolean("success", false)
                putString("downloadId", downloadId)
                putString("error", "CANCELLED")
              }
            )
            return@thread
          }
          // Network error — retry if attempts remain
          if (attempt < maxAttempts) {
            attempt++
            // loop continues → will sleep + retry
          } else {
            activeDownloads.remove(downloadId)
            foregroundPromises.remove(downloadId)?.resolve(Arguments.createMap().apply {
              putBoolean("success", false)
              putString("downloadId", downloadId)
              putString("error", lastError)
            })
            emit("onDownloadError", Arguments.createMap().apply {
              putBoolean("success", false)
              putString("downloadId", downloadId)
              putString("error", lastError)
            })
            return@thread
          }
        }
      }
    }
  }

  private fun pollBackgroundDownloads() {
    val dm = reactContext.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
    val query = DownloadManager.Query()
    val cursor = dm.query(query) ?: return
    val currentBgIds = bgDownloadIds.values.toSet()
    cursor.use { c ->
      if (c.moveToFirst()) {
        val idIdx = c.getColumnIndex(DownloadManager.COLUMN_ID)
        val statusIdx = c.getColumnIndex(DownloadManager.COLUMN_STATUS)
        val totalIdx = c.getColumnIndex(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)
        val currentIdx = c.getColumnIndex(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)
        val uriIdx = c.getColumnIndex(DownloadManager.COLUMN_URI)
        do {
          val bgId = c.getLong(idIdx)
          if (!currentBgIds.contains(bgId)) continue
          val downloadId = downloadIdForBgId(bgId) ?: continue
          val status = c.getInt(statusIdx)
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
  }

  private fun handleBackgroundDownloadComplete(bgId: Long) {
    val dm = reactContext.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
    val query = DownloadManager.Query().setFilterById(bgId)
    val cursor = dm.query(query) ?: return
    cursor.use {
      if (it.moveToFirst()) {
        val statusIdx = it.getColumnIndex(DownloadManager.COLUMN_STATUS)
        val uriIdx = it.getColumnIndex(DownloadManager.COLUMN_LOCAL_URI)
        val reasonIdx = it.getColumnIndex(DownloadManager.COLUMN_REASON)

        // Not one of ours (another library or the host app enqueued it).
        val downloadId = downloadIdForBgId(bgId) ?: return
        val status = it.getInt(statusIdx)
        forgetBackgroundDownload(downloadId, bgId)

        if (status == DownloadManager.STATUS_SUCCESSFUL) {
          val localUri = it.getString(uriIdx)
          // COLUMN_LOCAL_URI is a percent-encoded file:// URI; Uri.parse().path
          // decodes it, whereas trimming the scheme leaves "%20" in the path.
          val filePath = localUri?.let { uri -> Uri.parse(uri).path } ?: ""
          emit("onDownloadComplete", Arguments.createMap().apply {
            putBoolean("success", true)
            putString("downloadId", downloadId)
            putString("filePath", filePath)
          })
        } else {
          val reason = it.getInt(reasonIdx)
          emit("onDownloadError", Arguments.createMap().apply {
            putBoolean("success", false)
            putString("downloadId", downloadId)
            putString("error", "DownloadManager failed with reason/code: $reason")
          })
        }
      }
    }
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
    val state = activeDownloads[downloadId]
    if (state != null) {
      state.cancelled = true
      activeDownloads.remove(downloadId)
    }
    // Resolve foreground promise if download thread hasn't yet (atomic — safe from races)
    foregroundPromises.remove(downloadId)?.resolve(
      Arguments.createMap().apply {
        putBoolean("success", false)
        putString("downloadId", downloadId)
        putString("error", "CANCELLED")
      }
    )
    // Also cancel background DownloadManager downloads
    val bgId = bgDownloadIds[downloadId]
    if (bgId != null) {
      forgetBackgroundDownload(downloadId, bgId)
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
          if (!f.isFile) return@forEach
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
        dir.listFiles()?.forEach { it.deleteRecursively() }
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

      val dst = File(toPath)
      dst.parentFile?.mkdirs()
      src.copyTo(dst, overwrite = true)

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

      val dst = File(toPath)
      dst.parentFile?.mkdirs()

      val renamed = src.renameTo(dst)
      if (!renamed) {
        // renameTo fails across filesystems for both files and directories.
        // Fall back to recursive copy + delete, which works in all cases.
        src.copyRecursively(dst, overwrite = true)
        src.deleteRecursively()
      }

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
        val url = URL(urlString)
        val connection = url.openConnection() as HttpURLConnection
        
        connection.requestMethod = "GET"
        connection.connectTimeout = 30000
        connection.readTimeout = 30000

        // Add custom headers if provided
        headersMap?.toHashMap()?.forEach { (key, value) ->
          connection.setRequestProperty(key, value.toString())
        }

        connection.connect()

        val responseCode = connection.responseCode
        if (responseCode !in 200..299) {
          connection.disconnect()
          promise.resolve(Arguments.createMap().apply {
            putBoolean("success", false)
            putString("error", "HTTP $responseCode")
          })
          return@thread
        }

        // Get MIME type from response
        val mimeType = connection.contentType?.split(";")?.get(0)?.trim() ?: "application/octet-stream"

        // Read all bytes — cap at 50 MB to match readFile limit and prevent OOM.
        val maxBytes = 50L * 1024 * 1024
        val contentLength = connection.contentLength.toLong()
        if (contentLength > maxBytes) {
          connection.disconnect()
          promise.resolve(Arguments.createMap().apply {
            putBoolean("success", false)
            putString("error", "Response exceeds 50 MB limit for urlToBase64")
          })
          return@thread
        }
        val bytes = connection.inputStream.use { input ->
          val buf = input.readBytes()
          if (buf.size > maxBytes) {
            promise.resolve(Arguments.createMap().apply {
              putBoolean("success", false)
              putString("error", "Response exceeds 50 MB limit for urlToBase64")
            })
            return@thread
          }
          buf
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

      // Check if there's an app to handle this file type
      val packageManager = reactContext.packageManager
      if (openIntent.resolveActivity(packageManager) != null) {
        reactContext.startActivity(openIntent)
        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", true)
        })
      } else {
        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", false)
          putString("error", "No app found to open this file type: $detectedMimeType")
        })
      }

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
        destDirFile.mkdirs()

        val extractedFiles = Arguments.createArray()

        ZipInputStream(FileInputStream(sourceFile).buffered()).use { zis ->
          var entry: ZipEntry? = zis.nextEntry
          while (entry != null) {
            // Prevent zip-slip attacks
            val entryFile = File(destDirFile, entry.name)
            val canonicalDest = destDirFile.canonicalPath
            val canonicalEntry = entryFile.canonicalPath
            if (!canonicalEntry.startsWith(canonicalDest + File.separator) &&
                canonicalEntry != canonicalDest) {
              // Refuse to extract entries that escape the destination directory
              // (zip-slip attack). Return an error instead of silently skipping
              // to match iOS behaviour and prevent partial extractions.
              throw SecurityException("ZIP entry has invalid path: ${entry.name}")
            }

            if (entry.isDirectory) {
              entryFile.mkdirs()
            } else {
              entryFile.parentFile?.mkdirs()
              FileOutputStream(entryFile).buffered().use { fos ->
                zis.copyTo(fos)
              }
              extractedFiles.pushString(entryFile.absolutePath)
            }
            zis.closeEntry()
            entry = zis.nextEntry
          }
        }

        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", true)
          putString("destDir", destDirFile.absolutePath)
          putArray("files", extractedFiles)
        })
      } catch (e: Exception) {
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
        destFile.parentFile?.mkdirs()
        destFile.delete()

        ZipOutputStream(FileOutputStream(destFile).buffered()).use { zos ->
          if (sourceFile.isDirectory) {
            zipDirectory(sourceFile, sourceFile.name, zos)
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

  private fun zipDirectory(dir: File, baseName: String, zos: ZipOutputStream) {
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
        zipDirectory(file, entryName, zos)
      } else {
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
        // We read cookies for the domain and set each to expired.
        val cookieUrl = cookieUrlFor(domain)
        val cookieString = cookieManager.getCookie(cookieUrl)
        if (!cookieString.isNullOrBlank()) {
          cookieString.split(";").forEach { pair ->
            val trimmed = pair.trim()
            val eqIndex = trimmed.indexOf("=")
            if (eqIndex > 0) {
              val name = trimmed.substring(0, eqIndex)
              cookieManager.setCookie(cookieUrl, "$name=; Expires=Thu, 01 Jan 1970 00:00:00 GMT")
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

          resolver.openOutputStream(uri)?.use { outputStream ->
            FileInputStream(file).use { inputStream ->
              val buffer = ByteArray(8192)
              var count: Int
              while (inputStream.read(buffer).also { count = it } != -1) {
                outputStream.write(buffer, 0, count)
              }
            }
          }

          values.clear()
          values.put(android.provider.MediaStore.MediaColumns.IS_PENDING, 0)
          resolver.update(uri, values, null, null)

          promise.resolve(Arguments.createMap().apply {
            putBoolean("success", true)
            putString("uri", uri.toString())
          })
        } else {
          // Android 9 and below — copy to public directory and media-scan
          val destDir = when (mediaType) {
            "image" -> Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES)
            "video" -> Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES)
            "audio" -> Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC)
            else -> Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
          }

          val albumDir = if (album != null) File(destDir, album) else destDir
          albumDir.mkdirs()
          val destFile = File(albumDir, file.name)
          file.copyTo(destFile, overwrite = true)

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
  }
}

