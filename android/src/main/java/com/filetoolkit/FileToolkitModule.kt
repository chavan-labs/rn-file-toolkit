package com.filetoolkit

import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import androidx.core.content.FileProvider
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.Arguments
import com.facebook.react.modules.core.DeviceEventManagerModule
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URL
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

  // ─── Helpers ───────────────────────────────────────────────────────────────

  private fun emit(event: String, map: com.facebook.react.bridge.WritableMap) {
    reactContext
      .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
      .emit(event, map)
  }

  private fun resolveFileName(url: String, hint: String?): String {
    if (!hint.isNullOrBlank()) return hint
    var name = url.substringAfterLast("/")
    if (name.contains("?")) name = name.substringBefore("?")
    return name.ifBlank { "downloaded_file" }
  }

  private fun getDestinationFile(fileName: String, destination: String?): File {
    return when (destination) {
      "cache" -> File(reactContext.cacheDir, fileName)
      "documents" -> {
        // getExternalFilesDir can return null if external storage is unavailable
        val dir = reactContext.getExternalFilesDir(Environment.DIRECTORY_DOCUMENTS)
          ?: reactContext.filesDir
        File(dir, fileName)
      }
      else -> File(
        Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
        fileName
      )
    }
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
    val downloadId = UUID.randomUUID().toString()

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
    activeDownloads[downloadId] = state

    if (isBackground) {
      // Use system DownloadManager — survives process death
      val dm = reactContext.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
      val request = DownloadManager.Request(Uri.parse(urlString)).apply {
        setTitle(notificationTitle ?: fileName)
        setDescription(notificationDesc ?: "rn-file-toolkit-id:$downloadId")
        setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)

        // Add headers
        headersMap?.toHashMap()?.forEach { (key, value) ->
          if (value is String) addRequestHeader(key, value)
        }

        // Set destination
        when (destination) {
          "cache" -> setDestinationInExternalFilesDir(reactContext, null, fileName) // No specific 'cache' directory in DownloadManager, use files
          "documents" -> setDestinationInExternalFilesDir(reactContext, Environment.DIRECTORY_DOCUMENTS, fileName)
          else -> setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, fileName)
        }
      }
      val bgId = dm.enqueue(request)
      bgDownloadIds[downloadId] = bgId
      activeDownloads.remove(downloadId)

      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", true)
        putString("downloadId", downloadId)
      })
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
          val delayMs = (baseDelay.toLong() * (1L shl (attempt - 1))).coerceAtMost(30_000L)
          // Bug #5 fix: emit retry event BEFORE the delay so JS callback fires immediately
          val retryEvt = Arguments.createMap().apply {
            putString("downloadId", downloadId)
            putString("url", urlString)
            putInt("attempt", attempt)
            putString("error", lastError)
          }
          emit("onDownloadRetry", retryEvt)
          Thread.sleep(delayMs)
        }

        try {
          val resumeFrom = state.bytesDownloaded
          val destFile = getDestinationFile(fileName, destination)

          val url = URL(urlString)
          val connection = url.openConnection() as HttpURLConnection

          headersMap?.toHashMap()?.forEach { (key, value) ->
            if (value is String) connection.setRequestProperty(key, value)
          }

          if (resumeFrom > 0) {
            connection.setRequestProperty("Range", "bytes=$resumeFrom-")
          }
          connection.connect()

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

          foregroundPromises.remove(downloadId)?.resolve(Arguments.createMap().apply {
            putBoolean("success", true)
            putString("downloadId", downloadId)
            putString("filePath", destFile.absolutePath)
          })
          emit("onDownloadComplete", Arguments.createMap().apply {
            putBoolean("success", true)
            putString("downloadId", downloadId)
            putString("filePath", destFile.absolutePath)
          })
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

  // ─── pauseDownload ─────────────────────────────────────────────────────────

  override fun pauseDownload(downloadId: String, promise: Promise) {
    val state = activeDownloads[downloadId]
    if (state == null) {
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", false); putString("error", "Download not found")
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
      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", false); putString("error", "Download not found or already finished")
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
    val bgId = bgDownloadIds.remove(downloadId)
    if (bgId != null) {
      val dm = reactContext.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
      dm.remove(bgId)
    }
    promise.resolve(Arguments.createMap().apply { putBoolean("success", true) })
  }

  // ─── getCachedFiles ────────────────────────────────────────────────────────

  override fun getCachedFiles(promise: Promise) {
    try {
      val list = Arguments.createArray()

      // Scan all three directories: public downloads, cache, documents
      val dirs = listOfNotNull(
        Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
        reactContext.cacheDir,
        reactContext.getExternalFilesDir(Environment.DIRECTORY_DOCUMENTS) ?: reactContext.filesDir
      )

      for (dir in dirs) {
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
    val file = File(filePath)
    val deleted = file.delete()
    promise.resolve(Arguments.createMap().apply {
      putBoolean("success", deleted)
      if (!deleted) putString("error", "File not found or could not be deleted")
    })
  }

  // ─── clearCache ────────────────────────────────────────────────────────────

  override fun clearCache(promise: Promise) {
    try {
      // Only clear app-private directories — never touch public Downloads
      val dirs = listOfNotNull(
        reactContext.cacheDir,
        reactContext.getExternalFilesDir(Environment.DIRECTORY_DOCUMENTS) ?: reactContext.filesDir
      )
      for (dir in dirs) {
        dir.listFiles()?.forEach { it.delete() }
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
    } catch (e: Exception) {
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
    } catch (e: Exception) {
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

      val data = if (encoding.equals("base64", ignoreCase = true)) {
        android.util.Base64.encodeToString(file.readBytes(), android.util.Base64.NO_WRAP)
      } else {
        file.readText(Charsets.UTF_8)
      }

      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", true)
        putString("data", data)
      })
    } catch (e: Exception) {
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
    } catch (e: Exception) {
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
    } catch (e: Exception) {
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
        if (src.isDirectory) {
          promise.resolve(Arguments.createMap().apply {
            putBoolean("success", false)
            putString("error", "Moving directories is not supported")
          })
          return
        }
        src.copyTo(dst, overwrite = true)
        src.delete()
      }

      promise.resolve(Arguments.createMap().apply {
        putBoolean("success", true)
      })
    } catch (e: Exception) {
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
    } catch (e: Exception) {
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
    } catch (e: Exception) {
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

      if (cursor != null && cursor.moveToFirst()) {
        val descIdx = cursor.getColumnIndex(DownloadManager.COLUMN_DESCRIPTION)
        val idIdx = cursor.getColumnIndex(DownloadManager.COLUMN_ID)
        val statusIdx = cursor.getColumnIndex(DownloadManager.COLUMN_STATUS)
        val uriIdx = cursor.getColumnIndex(DownloadManager.COLUMN_URI)
        val totalIdx = cursor.getColumnIndex(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)
        val currentIdx = cursor.getColumnIndex(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)

        do {
          val description = cursor.getString(descIdx) ?: ""
          if (description.startsWith("rn-file-toolkit-id:")) {
            val downloadId = description.removePrefix("rn-file-toolkit-id:")
            val status = cursor.getInt(statusIdx)
            val total = cursor.getLong(totalIdx)
            val current = cursor.getLong(currentIdx)
            val progress = if (total > 0) (current * 100 / total).toInt() else 0

            results.pushMap(Arguments.createMap().apply {
              putString("downloadId", downloadId)
              putString("url", cursor.getString(uriIdx))
              putInt("status", status)
              putInt("progress", progress)
            })
          }
        } while (cursor.moveToNext())
        cursor.close()
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
        connection.setRequestProperty("Connection", "Keep-Alive")
        connection.setRequestProperty("Content-Type", "multipart/form-data; boundary=$boundary")

        // Add custom headers
        headersMap?.toHashMap()?.forEach { (key, value) ->
          if (value is String) connection.setRequestProperty(key, value)
        }

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
          writer.close()
        } finally {
          try { fileInput.close() } catch (_: Exception) {}
        }

        val responseCode = connection.responseCode
        val responseBody = if (responseCode in 200..299) {
          connection.inputStream.bufferedReader().use { it.readText() }
        } else {
          connection.errorStream?.bufferedReader()?.use { it.readText() } ?: ""
        }

        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", responseCode in 200..299)
          putInt("status", responseCode)
          putString("data", responseBody)
          if (responseCode !in 200..299) putString("error", "HTTP $responseCode")
        })

      } catch (e: Exception) {
        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", false)
          putString("error", e.message ?: "UPLOAD_ERROR")
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

    } catch (e: Exception) {
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

        if (connection.responseCode !in 200..299) {
          promise.resolve(Arguments.createMap().apply {
            putBoolean("success", false)
            putString("error", "HTTP ${connection.responseCode}")
          })
          return@thread
        }

        // Get MIME type from response
        val mimeType = connection.contentType?.split(";")?.get(0)?.trim() ?: "application/octet-stream"

        // Read all bytes
        val bytes = connection.inputStream.use { it.readBytes() }
        
        // Encode to base64
        val base64String = android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)

        promise.resolve(Arguments.createMap().apply {
          putBoolean("success", true)
          putString("base64", base64String)
          putString("mimeType", mimeType)
          putString("dataUri", "data:$mimeType;base64,$base64String")
        })

      } catch (e: Exception) {
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

      val authority = "${reactContext.packageName}.fileprovider"
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

      val authority = "${reactContext.packageName}.fileprovider"
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
              entry = zis.nextEntry
              continue
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

  companion object {
    const val NAME = NativeFileToolkitSpec.NAME
  }
}

