package app.astoria.flutter

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Metadata only: no directory creation, rows, vault access or file selection. */
internal object SnapshotStorageChannel {
    fun register(context: Context, messenger: BinaryMessenger) {
        MethodChannel(messenger, "app.astoria.flutter/snapshot_storage")
            .setMethodCallHandler { call, result ->
                if (call.method != "privateNamespace" || call.arguments != null) {
                    result.notImplemented()
                } else {
                    try {
                        // No getNoBackupFilesDir(): that accessor can create it
                        // before the user has confirmed the actual snapshot.
                        result.success(File(context.applicationInfo.dataDir).canonicalPath)
                    } catch (_: Exception) {
                        result.error("unavailable", "Private snapshot storage unavailable", null)
                    }
                }
            }
    }
}
