package com.plugchoice

import android.app.Activity
import android.content.Context
import android.content.Intent
import androidx.activity.result.contract.ActivityResultContract
import com.plugchoice.internal.Instances
import com.plugchoice.internal.LinkIntents
import com.plugchoice.internal.Transports

/**
 * The Plugchoice SDK. Create one instance with a callback that fetches a client secret from your
 * server, and open its features from it:
 *
 * ```kotlin
 * val plugchoice = Plugchoice(fetchClientSecret = { action -> backend.plugchoiceClientSecret(action) })
 *
 * private val openLink = registerForActivityResult(plugchoice.link.contract()) { result: LinkResult -> … }
 * openLink.launch(LinkAction.reconnect(chargerId))
 * ```
 *
 * @param fetchClientSecret Returns a client secret your server got from
 *   `POST /sdk/v1/client-sessions`, scoped to the [LinkAction] it is given: the action the screen
 *   was opened with (its charger or site). Called once when a screen opens (in parallel with
 *   loading it) and again, with the same action, whenever the page's secret has expired. Called on
 *   the main thread: do the network call in a suspending client (or switch dispatchers). A throw,
 *   an empty string or no answer within 30 s shows the page's error screen with "Try again". The
 *   SDK never logs the secret.
 * @param options See [Options].
 */
public class Plugchoice(
    fetchClientSecret: suspend (LinkAction) -> String,
    public val options: Options = Options(),
) {
    internal val fetchClientSecret: suspend (LinkAction) -> String = fetchClientSecret

    /** Link, the onboarding feature: add a charger, set it up, reconnect it (or change its network). */
    public val link: Link = Link(this)

    /**
     * @property hostOverride Debug builds only: an origin such as `"http://192.168.1.20:5173"` (a
     *   local Link UI) that replaces the scheme, host and port of [ORIGIN] and becomes the only
     *   origin the screen loads and lets use the bridge. Honoured only when the host app is
     *   debuggable (`ApplicationInfo.FLAG_DEBUGGABLE`); ignored with a log line otherwise.
     */
    public data class Options(
        public val hostOverride: String? = null,
    )

    /**
     * Opens the Link screen. With the Activity Result API:
     * `registerForActivityResult(plugchoice.link.contract()) { result -> … }`, then
     * `launch(LinkAction.addCharger())`. Without it: start [intent] for a result and read it with
     * [parseResult].
     */
    public class Link internal constructor(private val plugchoice: Plugchoice) {

        /** The Activity Result API contract: launched with a [LinkAction], answers a [LinkResult]. */
        public fun contract(): ActivityResultContract<LinkAction, LinkResult> = LinkContract(this)

        /**
         * An intent that opens the Link screen for [action], for `startActivityForResult`. Read the
         * result with [parseResult]. While the screen is open it calls this instance's
         * `fetchClientSecret` with [action].
         */
        public fun intent(context: Context, action: LinkAction): Intent =
            LinkIntents.open(context, action, Instances.register(plugchoice, action), plugchoice.options.hostOverride)

        /**
         * Reads the result of an activity started with [intent]. Anything unexpected (the screen
         * gone without a result) reads as `cancelled`, with [fallbackAction] as the action.
         */
        @JvmOverloads
        public fun parseResult(resultCode: Int, data: Intent?, fallbackAction: String = ""): LinkResult {
            data?.let(LinkIntents::instanceId)?.let(Instances::release)
            if (resultCode != Activity.RESULT_OK || data == null) {
                return LinkResult(LinkResult.Status.CANCELLED, fallbackAction)
            }
            return LinkIntents.result(data, fallbackAction)
        }
    }

    public companion object {
        /** The SDK release, reported to the page as `hello.sdkVersion` (the same on iOS). */
        public const val SDK_VERSION: String = "0.6.0" // x-release-please-version

        /** The only origin the screens load and let use the bridge (outside [Options.hostOverride]). */
        public const val ORIGIN: String = "https://connect.plugchoice.com"

        /**
         * What this device and app can do, without opening anything or asking for a permission:
         * any of `"wifi"` (joining a device's Wi-Fi), `"http"` (HTTP and WebSocket on the local
         * network), `"socket"` (raw TCP and UDP), `"lan"` (finding devices on the local network)
         * and `"ble"` (Bluetooth LE: the device has it and the app kept the SDK's Bluetooth
         * permissions). Compare them with a device's `capabilities.*.needs` to decide whether to
         * offer an action.
         */
        @JvmStatic
        public fun transports(context: Context): List<String> = Transports.available(context)
    }
}

/** [Plugchoice.Link.contract]: remembers the action it launched, for a result that never came. */
private class LinkContract(private val link: Plugchoice.Link) : ActivityResultContract<LinkAction, LinkResult>() {
    private var lastAction = ""

    override fun createIntent(context: Context, input: LinkAction): Intent {
        lastAction = input.name
        return link.intent(context, input)
    }

    override fun parseResult(resultCode: Int, intent: Intent?): LinkResult =
        link.parseResult(resultCode, intent, lastAction)
}
