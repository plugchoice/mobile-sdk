package com.plugchoice.reactnative

import com.plugchoice.LinkAction
import com.plugchoice.LinkResult
import com.plugchoice.Plugchoice
import expo.modules.kotlin.Promise
import expo.modules.kotlin.exception.Exceptions
import expo.modules.kotlin.functions.Queues
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.kotlin.records.Field
import expo.modules.kotlin.records.Record

/**
 * `@plugchoice/react-native` on Android, over the Plugchoice SDK (`com.plugchoice`).
 *
 * - `openLink(action, options)` starts the Link screen ([Plugchoice.Link.intent]) and resolves with
 *   the [LinkResult] when it finishes. One at a time: a call while one is open rejects with
 *   `ERR_LINK_ALREADY_OPEN`.
 * - The SDK's `fetchClientSecret` asks JavaScript, which holds the app's callback
 *   ([ClientSecretRequests]): it sends `onClientSecretRequest { requestId, action }` and waits for
 *   `provideClientSecret(requestId, secret)` or `rejectClientSecret(requestId, message)`. The SDK
 *   stops waiting after 30 s (`clientSecretUnavailable` to the page).
 * - `getTransports()` is [Plugchoice.transports].
 *
 * The screen is started with `startActivityForResult` rather than Expo's activity result registry,
 * which persists launch inputs to SharedPreferences when the host activity is destroyed.
 */
class PlugchoiceModule : Module() {
    private val clientSecrets = ClientSecretRequests { body -> sendEvent(ClientSecretRequests.EVENT, body) }

    /** The open screen. Main thread only. */
    private var open: OpenScreen? = null

    private class OpenScreen(val promise: Promise, val plugchoice: Plugchoice, val action: String)

    override fun definition() = ModuleDefinition {
        Name("Plugchoice")

        Events(ClientSecretRequests.EVENT)

        AsyncFunction("openLink") { action: LinkActionRecord, options: OpenLinkOptions, promise: Promise ->
            if (open != null) {
                promise.reject(ALREADY_OPEN, "A Plugchoice Link screen is already open.", null)
                return@AsyncFunction
            }
            val activity = appContext.currentActivity
            if (activity == null || activity.isFinishing) {
                promise.reject(CANNOT_PRESENT, "There is no activity to start Plugchoice Link from.", null)
                return@AsyncFunction
            }
            val linkAction = action.toLinkAction()
            val plugchoice = Plugchoice(
                fetchClientSecret = clientSecrets::request,
                options = Plugchoice.Options(hostOverride = options.hostOverride),
            )
            open = OpenScreen(promise, plugchoice, linkAction.name)
            @Suppress("DEPRECATION")
            activity.startActivityForResult(plugchoice.link.intent(activity, linkAction), REQUEST_CODE)
        }.runOnQueue(Queues.MAIN)

        Function("provideClientSecret") { requestId: String, clientSecret: String ->
            clientSecrets.answer(requestId, Result.success(clientSecret))
        }

        Function("rejectClientSecret") { requestId: String, message: String ->
            clientSecrets.answer(requestId, Result.failure(ClientSecretRejected(message)))
        }

        AsyncFunction("getTransports") {
            Plugchoice.transports(appContext.reactContext ?: throw Exceptions.ReactContextLost())
        }

        OnActivityResult { _, payload ->
            if (payload.requestCode != REQUEST_CODE) return@OnActivityResult
            val screen = open ?: return@OnActivityResult
            open = null
            val result = screen.plugchoice.link.parseResult(payload.resultCode, payload.data, screen.action)
            screen.promise.resolve(result.toPayload())
        }

        OnDestroy {
            // JavaScript is going away (a reload): the screen's result and its secret requests have
            // nowhere to go.
            open = null
            clientSecrets.close()
        }
    }

    private companion object {
        const val REQUEST_CODE = 0x504C // "PL"
        const val ALREADY_OPEN = "ERR_LINK_ALREADY_OPEN"
        const val CANNOT_PRESENT = "ERR_LINK_CANNOT_PRESENT"
    }
}

/** The action JavaScript opens Link with. */
class LinkActionRecord : Record {
    @Field
    val action: String = ""

    @Field
    val chargerId: String? = null

    @Field
    val siteId: String? = null

    /** Empty ids are left out ([LinkAction.custom]); a blank action throws. */
    fun toLinkAction(): LinkAction = LinkAction.custom(action, chargerId, siteId)
}

class OpenLinkOptions : Record {
    /** Debug builds only; see [Plugchoice.Options.hostOverride]. */
    @Field
    val hostOverride: String? = null
}

/** `{ action, chargerId?, siteId? }`. */
internal fun LinkAction.toPayload(): Map<String, Any> = buildMap {
    put("action", name)
    chargerId?.let { put("chargerId", it) }
    siteId?.let { put("siteId", it) }
}

/** `{ status, action, sessionId?, devices: [{ type, id }], error?: { code, message? } }`; JavaScript fills in the rest. */
internal fun LinkResult.toPayload(): Map<String, Any> = buildMap {
    put("status", status.value)
    put("action", action)
    put("devices", devices.map { mapOf("type" to it.type, "id" to it.id) })
    sessionId?.let { put("sessionId", it) }
    error?.let { error ->
        put(
            "error",
            buildMap {
                put("code", error.code)
                error.message?.let { put("message", it) }
            },
        )
    }
}
