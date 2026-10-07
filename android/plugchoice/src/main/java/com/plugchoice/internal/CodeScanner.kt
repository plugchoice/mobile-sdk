package com.plugchoice.internal

import android.util.Log
import com.google.android.gms.common.moduleinstall.InstallStatusListener
import com.google.android.gms.common.moduleinstall.ModuleInstall
import com.google.android.gms.common.moduleinstall.ModuleInstallClient
import com.google.android.gms.common.moduleinstall.ModuleInstallRequest
import com.google.android.gms.common.moduleinstall.ModuleInstallStatusUpdate.InstallState
import com.google.android.gms.tasks.Task
import com.google.mlkit.common.MlKitException
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScanner
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * `camera.scanCode` (PROTOCOL.md §10) with the Google code scanner: Play services draws the
 * full-screen scanner and owns the camera, so the app needs no camera permission and no UI of
 * our own. It has no place for the page's `title` and `hint`; they are accepted and not shown.
 *
 * The scanned value can hold secrets (a charger's setup card QR can carry its hotspot password):
 * it is never logged.
 */
internal class CodeScanner(private val host: BridgeHost) {

    private var scanning = false

    suspend fun scan(params: JSONObject): JSONObject {
        val formats = params.optStringList("formats")
        if (formats.isEmpty() || formats.any { it != FORMAT_QR }) {
            throw BridgeException.invalidParams("formats must be [\"qr\"]")
        }
        params.optStringOrNull("title")
        params.optStringOrNull("hint")
        if (scanning) throw BridgeException(ErrorCode.UNAVAILABLE, "a scan is already in progress")

        scanning = true
        try {
            val context = host.hostContext // the activity: the scanner starts from it
            val scanner = GmsBarcodeScanning.getClient(context, OPTIONS)
            ensureModuleInstalled(ModuleInstall.getClient(context), scanner)
            val barcode = try {
                scanner.startScan().await()
            } catch (_: TaskCanceledException) {
                throw BridgeException(ErrorCode.USER_CANCELLED, "scan cancelled")
            } catch (e: MlKitException) {
                throw scanError(e)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                throw BridgeException(ErrorCode.UNAVAILABLE, "code scanner failed: ${e.javaClass.simpleName}")
            }
            val value = barcode.rawValue
                ?: throw BridgeException(ErrorCode.INTERNAL, "the code holds no text")
            return JSONObject().put("value", value).put("format", FORMAT_QR)
        } finally {
            scanning = false
        }
    }

    /**
     * The scanner lives in a Play services module that is downloaded on first use; a scan started
     * before it is there fails. Ask for it now and wait (the page shows its own progress meanwhile).
     */
    private suspend fun ensureModuleInstalled(modules: ModuleInstallClient, scanner: GmsBarcodeScanner) {
        val available = try {
            modules.areModulesAvailable(scanner).await().areModulesAvailable()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // ApiException: no (usable) Play services on this device.
            throw BridgeException(ErrorCode.UNAVAILABLE, "Google Play services can't provide the code scanner: $e")
        }
        if (available) return

        Log.i(TAG, "downloading the code scanner module")
        val installed = CompletableDeferred<Unit>()
        val listener = InstallStatusListener { update ->
            when (update.installState) {
                InstallState.STATE_COMPLETED -> installed.complete(Unit)
                InstallState.STATE_CANCELED, InstallState.STATE_FAILED -> installed.completeExceptionally(
                    BridgeException(ErrorCode.UNAVAILABLE, "code scanner module download failed (${update.errorCode})"),
                )
            }
        }
        val request = ModuleInstallRequest.newBuilder().addApi(scanner).setListener(listener).build()
        try {
            if (modules.installModules(request).await().areModulesAlreadyInstalled()) return
            withTimeout(MODULE_INSTALL_TIMEOUT_MS) { installed.await() }
        } catch (_: TimeoutCancellationException) {
            throw BridgeException(ErrorCode.UNAVAILABLE, "code scanner module not downloaded within ${MODULE_INSTALL_TIMEOUT_MS}ms")
        } catch (e: CancellationException) {
            throw e
        } catch (e: BridgeException) {
            throw e
        } catch (e: Exception) {
            throw BridgeException(ErrorCode.UNAVAILABLE, "code scanner module download failed: $e")
        } finally {
            modules.unregisterListener(listener)
        }
    }

    private fun scanError(e: MlKitException): BridgeException = when (e.errorCode) {
        MlKitException.CODE_SCANNER_CANCELLED ->
            BridgeException(ErrorCode.USER_CANCELLED, "scan cancelled")
        MlKitException.CODE_SCANNER_CAMERA_PERMISSION_NOT_GRANTED ->
            BridgeException(ErrorCode.CAMERA_PERMISSION_DENIED, "camera permission not granted to the code scanner")
        // Unavailable module, Play services too old, pipeline errors, another scan in progress.
        else -> BridgeException(ErrorCode.UNAVAILABLE, "code scanner failed (${e.errorCode})")
    }

    private class TaskCanceledException : Exception()

    /** Waits for a Play services task (listeners run on the main thread). */
    private suspend fun <T> Task<T>.await(): T = suspendCancellableCoroutine { continuation ->
        addOnCompleteListener { task ->
            when {
                task.isCanceled -> continuation.resumeWithException(TaskCanceledException())
                task.exception != null -> continuation.resumeWithException(task.exception!!)
                else -> continuation.resume(task.result)
            }
        }
    }

    private companion object {
        const val TAG = "Plugchoice"
        const val FORMAT_QR = "qr"
        const val MODULE_INSTALL_TIMEOUT_MS = 60_000L

        val OPTIONS: GmsBarcodeScannerOptions = GmsBarcodeScannerOptions.Builder()
            .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
            .enableAutoZoom()
            .build()
    }
}
