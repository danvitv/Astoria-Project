package app.astoria.flutter

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.Executors

/** Ciphertext-only SAF custody. No paths/URIs, key material or diagnostics cross
 * the channel. ACTION_CREATE_DOCUMENT (not OPEN_DOCUMENT) creates a NEW document;
 * compliant providers choose a new name rather than overwriting an existing one.
 * A successful provider close/flush is not a claim about cloud sync/durability.
 */
internal class SupportReportSaveChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    companion object {
        private const val CHANNEL = "app.astoria/support-report-save"
        private const val REQUEST_CODE = 0x6A31
        private const val NEUTRAL_NAME = "astoria-support-report.astreport"
        private const val MAX_BYTES = 4 * 1024 * 1024
        private const val CHUNK_BYTES = 64 * 1024
        private val MAGIC = byteArrayOf(65, 83, 84, 82, 80, 84, 49, 0)
        private val pickerLock = Any()
        // Survives Activity replacement solely to discard/clean the ORIGINAL
        // canceled create result. A new Activity never adopts its destination.
        private var pickerOwner: SupportReportSaveChannel? = null
    }

    private class Request(val id: String) {
        var token: String? = null
        var uri: Uri? = null
        var createdEmpty = false
        var canceled = false
        var consumed = false
        var writing = false
        var choice: Selection? = null
    }

    private class Selection(val request: Request, var reply: MethodChannel.Result?)

    private val channel = MethodChannel(messenger, CHANNEL)
    private val resolver = activity.applicationContext.contentResolver
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val lock = Any()
    private var closed = false
    private var active: Request? = null
    // Retain a canceled selector tombstone until its own late result arrives.
    // Never reuse its request code for another request while that result is live.
    private var selection: Selection? = null

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "beginRequest" -> begin(call, result)
                    "choose" -> choose(call, result)
                    "commit" -> commit(call, result)
                    "cancel" -> cancel(call, result)
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                // Do not pass provider exceptions (which can contain URIs).
                result.success(outcome("failed", "native_unavailable"))
            }
        }
    }

    private fun alive() = !closed && !activity.isFinishing && !activity.isDestroyed

    private fun outcome(status: String, code: String) = mapOf("status" to status, "code" to code)

    private fun begin(call: MethodCall, result: MethodChannel.Result) {
        synchronized(lock) {
            if (call.arguments != null || !alive() || active != null || selection != null ||
                synchronized(pickerLock) { pickerOwner != null }) {
                result.success(outcome("refused", "unavailable_or_busy"))
                return
            }
            val request = Request(UUID.randomUUID().toString())
            active = request
            result.success(mapOf("status" to "ready", "request" to request.id))
        }
    }

    private fun owned(call: MethodCall): Request? {
        val id = call.argument<String>("request") ?: return null
        return active?.takeIf { it.id == id && !it.canceled && alive() }
    }

    private fun exactArguments(call: MethodCall, keys: Set<String>): Boolean =
        (call.arguments as? Map<*, *>)?.keys == keys

    private fun choose(call: MethodCall, result: MethodChannel.Result) {
        synchronized(lock) {
            val request = owned(call)
            if (!exactArguments(call, setOf("request", "neutralName")) ||
                call.argument<String>("neutralName") != NEUTRAL_NAME || request == null ||
                selection != null || request.token != null || request.consumed) {
                result.success(outcome("refused", "invalid_request"))
                return
            }
            val claimed = synchronized(pickerLock) {
                if (pickerOwner != null) false else { pickerOwner = this; true }
            }
            if (!claimed) {
                result.success(outcome("refused", "selector_busy"))
                return
            }
            val pending = Selection(request, result)
            request.choice = pending
            selection = pending
            try {
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "application/octet-stream"
                    putExtra(Intent.EXTRA_TITLE, NEUTRAL_NAME)
                }
                activity.startActivityForResult(intent, REQUEST_CODE)
            } catch (_: Exception) {
                selection = null
                request.choice = null
                synchronized(pickerLock) { if (pickerOwner === this) pickerOwner = null }
                request.canceled = true
                active = null
                result.success(outcome("failed", "selector_unavailable"))
            }
        }
    }

    /** Consume only our own live/tombstoned request; all plugins keep their results. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val oldOwner = synchronized(pickerLock) { pickerOwner }
        if (oldOwner != null && oldOwner !== this && oldOwner.closed) {
            return oldOwner.onActivityResult(requestCode, resultCode, data)
        }
        val picked = synchronized(lock) {
            val pending = selection ?: return false
            selection = null
            pending
        }
        synchronized(pickerLock) { if (pickerOwner === this) pickerOwner = null }
        val request = picked.request
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || uri.scheme != "content") {
            synchronized(lock) {
                request.canceled = true
                if (active === request) active = null
            }
            picked.reply?.success(outcome("canceled", "no_document"))
            picked.reply = null
            request.choice = null
            if (closed) worker.shutdown()
            return true
        }
        // Query off the UI thread. A CREATE_DOCUMENT result is owned only if it
        // is a SAF document that is positively observed empty. Nonempty/unknown
        // results are never opened/truncated/deleted. No persistable URI grant.
        worker.execute {
            val empty = isEmptyCreatedDocument(uri)
            val accepted = synchronized(lock) {
                request.uri = uri
                request.createdEmpty = empty
                if (empty && active === request && !request.canceled && alive()) {
                    request.token = UUID.randomUUID().toString()
                    true
                } else {
                    request.canceled = true
                    if (active === request) active = null
                    false
                }
            }
            if (!accepted) cleanup(request)
            main.post {
                // Cancellation during the query can revoke this destination.
                val token = synchronized(lock) {
                    request.token?.takeIf { accepted && !request.canceled && alive() }
                }
                if (token != null) {
                    picked.reply?.success(mapOf("status" to "selected", "token" to token))
                } else {
                    picked.reply?.success(outcome("canceled", "selection_invalidated"))
                }
                picked.reply = null
                request.choice = null
                if (closed) worker.shutdown()
            }
        }
        return true
    }

    private fun commit(call: MethodCall, result: MethodChannel.Result) {
        val bytes = call.argument<ByteArray>("bytes")
        val request: Request
        val frozen: ByteArray
        synchronized(lock) {
            val candidate = owned(call)
            if (!exactArguments(call, setOf("request", "token", "neutralName", "bytes")) ||
                candidate == null || candidate.consumed || candidate.token == null ||
                candidate.token != call.argument<String>("token") ||
                call.argument<String>("neutralName") != NEUTRAL_NAME) {
                result.success(outcome("refused", "invalid_destination"))
                return
            }
            candidate.consumed = true // One attempt, including malformed bytes.
            candidate.token = null
            if (bytes == null || !structuralCiphertext(bytes) || !candidate.createdEmpty) {
                candidate.canceled = true
                active = null
                worker.execute { cleanup(candidate) }
                result.success(outcome("refused", "invalid_ciphertext"))
                return
            }
            request = candidate
            frozen = bytes.copyOf() // No caller-owned mutable buffer in worker.
            request.writing = true
        }
        worker.execute { write(request, frozen, result) }
    }

    // Native defense in depth, not cryptography. Dart's trusted codec validator
    // additionally checks the canonical header and recipient/envelope structure.
    private fun structuralCiphertext(bytes: ByteArray): Boolean {
        if (bytes.size < 16 || bytes.size > MAX_BYTES ||
            MAGIC.indices.any { bytes[it] != MAGIC[it] }) return false
        fun u32(offset: Int): Long = (0..3).fold(0L) { n, i ->
            (n shl 8) or (bytes[offset + i].toLong() and 255L)
        }
        val header = u32(8)
        val ciphertext = u32(12)
        // These stricter framing ceilings match ASTRPT1 (256 KiB JSON payload).
        return header in 1L..1024L && ciphertext in 16L..(256L * 1024L + 16L) &&
            bytes.size.toLong() == 16L + header + ciphertext
    }

    private fun write(request: Request, bytes: ByteArray, result: MethodChannel.Result) {
        var admitted = false
        var payloadAttempted = false
        var saved = false
        var code = "document_changed"
        try {
            val uri = request.uri
            if (uri != null && isEmptyCreatedDocument(uri)) {
                val permitted = synchronized(lock) {
                    // Final cancellation/lifecycle check, serialized with cancel.
                    // This claims native open admission, not physical persistence.
                    // Never hold the monitor across blocking provider I/O: cancel
                    // must remain responsive even when an OS provider stalls.
                    if (active !== request || request.canceled || !alive()) false
                    else { admitted = true; true }
                }
                // No coroutine/queue/await between native admission and open.
                // Cancellation AFTER admission cannot revoke the admitted OS
                // call, but chunk checks stop further ciphertext best-effort.
                val stream = if (permitted) resolver.openOutputStream(uri, "w") else null
                if (stream != null) {
                    stream.use {
                        var offset = 0
                        while (offset < bytes.size) {
                            if (synchronized(lock) { request.canceled || closed }) {
                                throw java.io.IOException() // No text/URI in error.
                            }
                            val count = minOf(CHUNK_BYTES, bytes.size - offset)
                            payloadAttempted = true // A throwing write may be partial.
                            it.write(bytes, offset, count)
                            offset += count
                        }
                        it.flush()
                    }
                    saved = true // Even if cancel arrives after successful close.
                } else {
                    code = "open_refused"
                }
            }
        } catch (_: Exception) {
            code = "write_incomplete"
        } finally {
            bytes.fill(0)
        }
        // Never delete a nonempty changed document that we did not write.
        if (!saved) cleanup(request, partialWritten = payloadAttempted)
        val canceled = synchronized(lock) {
            request.writing = false
            if (active === request) active = null
            request.canceled
        }
        val response = when {
            saved -> outcome("saved", "saved")
            admitted -> outcome("failed", "write_incomplete")
            canceled -> outcome("canceled", "before_open")
            else -> outcome("failed", code)
        }
        main.post { result.success(response) }
    }

    private fun isEmptyCreatedDocument(uri: Uri): Boolean = try {
        if (!DocumentsContract.isDocumentUri(activity.applicationContext, uri)) false
        else resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use {
            val size = it.getColumnIndex(OpenableColumns.SIZE)
            it.moveToFirst() && size >= 0 && !it.isNull(size) && it.getLong(size) == 0L
        } == true
    } catch (_: Exception) { false }

    /** Best effort ONLY our CREATE_DOCUMENT result, positively observed empty,
     * or our admitted partial ciphertext. Never arbitrary/user-selected documents.
     * External provider races/dishonesty cannot be certified by this adapter.
     */
    private fun cleanup(request: Request, partialWritten: Boolean = false) {
        val uri = request.uri ?: return
        if (!request.createdEmpty || (!partialWritten && !isEmptyCreatedDocument(uri))) return
        try {
            DocumentsContract.deleteDocument(resolver, uri)
        } catch (_: Exception) { /* Cleanup failure may leave empty/partial ciphertext. */ }
    }

    private fun cancel(call: MethodCall, result: MethodChannel.Result) {
        if (!exactArguments(call, setOf("request"))) {
            result.success(null)
            return
        }
        val request = synchronized(lock) {
            active?.takeIf { it.id == call.argument<String>("request") }
        }
        if (request != null) invalidate(request)
        result.success(null)
    }

    private fun invalidate(request: Request) {
        val pending = synchronized(lock) {
            request.canceled = true
            request.token = null
            // The result remains revocable during the background empty-query,
            // not just while the system selector Activity is on screen.
            val pending = request.choice
            if (!request.writing && active === request) active = null
            pending
        }
        pending?.reply?.success(outcome("canceled", "selection_canceled"))
        pending?.reply = null
        if (synchronized(lock) { selection?.request === request }) {
            try { activity.finishActivity(REQUEST_CODE) } catch (_: Exception) { }
        }
        // A worker already owning a write is responsible for truthful completion.
        if (!synchronized(lock) { request.writing }) worker.execute { cleanup(request) }
    }

    fun close() {
        val request = synchronized(lock) {
            if (closed) return
            closed = true
            active
        }
        request?.let { invalidate(it) }
        channel.setMethodCallHandler(null)
        // Do not interrupt admitted I/O or falsely report that no file exists.
        // A canceled late CREATE_DOCUMENT may still require empty-document
        // cleanup, including after Activity replacement. Keep that worker until
        // the private result is consumed; it never opens a payload destination.
        if (synchronized(lock) { selection == null }) worker.shutdown()
    }
}
