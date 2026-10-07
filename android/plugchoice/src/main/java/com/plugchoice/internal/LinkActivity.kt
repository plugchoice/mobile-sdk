package com.plugchoice.internal

import android.annotation.SuppressLint
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.addCallback
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.plugchoice.LinkError
import com.plugchoice.LinkResult
import com.plugchoice.R
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * The Link screen: shows the hosted page full screen in a WebView with a native close button, and
 * bridges it to Wi-Fi, the local network, Bluetooth, the code scanner, the host app's client
 * secret and closing (`bridge/PROTOCOL.md`). Started by `Plugchoice.link.contract()` or
 * `Plugchoice.link.intent(...)`.
 *
 * It opens `https://connect.plugchoice.com/#action=…` and only that origin may use the bridge
 * (§2); debug host apps can point it at a local Link UI with `Plugchoice.Options.hostOverride`.
 * The intent names the `Plugchoice` instance whose `fetchClientSecret` the page reaches, called
 * with the screen's action ([Instances]); the instance is released when the screen finishes.
 *
 * The screen stays awake while open (the charger hotspot drops when the phone locks), and the
 * activity handles configuration changes itself so the page is never reloaded mid-flow.
 *
 * When the page doesn't load (no internet, server unreachable) the screen shows "Try again" with
 * the native close button, like iOS. Leaving from there reports `error` / `pageLoadFailed`.
 */
internal class LinkActivity : ComponentActivity() {

    private var webView: WebView? = null
    private var bridge: LinkBridge? = null
    private var origins: OriginAllowList? = null
    private var closeButton: View? = null
    private var loadErrorView: View? = null
    private var loadErrorDetail: TextView? = null
    private var destination: LinkDestination? = null
    /** Why the page didn't load, while the load-error screen shows. */
    private var loadError: String? = null
    /** The action the screen opened with, for the results the shell reports itself. */
    private var action: String = ""
    private var instanceId: String? = null
    private var finished = false

    private val permissionMutex = Mutex()
    private var pendingPermissions: CompletableDeferred<Map<String, Boolean>>? = null

    // Play services (the code scanner) brings androidx.fragment 1.0; the check is about
    // FragmentActivity, and this is a plain ComponentActivity.
    @SuppressLint("InvalidFragmentVersionForActivityResult")
    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { granted ->
            pendingPermissions?.complete(granted)
            pendingPermissions = null
        }

    private val host = object : BridgeHost {
        override val hostContext: Context
            get() = this@LinkActivity

        override suspend fun requestPermissions(permissions: Array<String>): Map<String, Boolean> =
            permissionMutex.withLock {
                val deferred = CompletableDeferred<Map<String, Boolean>>()
                pendingPermissions = deferred
                permissionLauncher.launch(permissions)
                deferred.await()
            }

        override fun closeSession(result: LinkResult) {
            finishWith(result)
        }

        override fun setNativeCloseButtonVisible(visible: Boolean) {
            closeButton?.visibility = if (visible) View.VISIBLE else View.GONE
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT),
        )
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        onBackPressedDispatcher.addCallback(this) { requestClose() }

        instanceId = LinkIntents.instanceId(intent)
        val linkAction = LinkIntents.action(intent)
        if (linkAction == null) {
            finishWithError(LinkError.INTERNAL, "The Link screen was started without an action; use Plugchoice.link")
            return
        }
        action = linkAction.name
        // Whatever ends this screen from here on (even something we don't see) reads as cancelled.
        setResult(RESULT_OK, LinkIntents.resultIntent(cancelledResult(), instanceId))

        // §2: lock the host before anything is shown or loaded.
        val debuggable = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        val destination = LinkDestination.resolve(
            linkAction,
            hostOverride = LinkIntents.hostOverride(intent),
            overrideAllowed = debuggable,
            onOverrideIgnored = { Log.w(TAG, it) },
        )
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            finishWithError(
                LinkError.INTERNAL,
                "This WebView can't host the Link bridge; update Android System WebView",
            )
            return
        }
        val allowList = OriginAllowList(destination.origin)
        origins = allowList
        this.destination = destination

        if (debuggable) {
            WebView.setWebContentsDebuggingEnabled(true) // chrome://inspect in debug builds
        }
        val webView = try {
            WebView(this)
        } catch (e: RuntimeException) {
            // No WebView provider installed, or it is being updated.
            finishWithError(LinkError.INTERNAL, "Could not create a WebView: $e")
            return
        }
        this.webView = webView
        configure(webView)

        val bridge = LinkBridge(host, webView, allowList, action, clientSecretSource())
        try {
            // Before loadUrl, so the object exists when the page's scripts run.
            if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
                WebViewCompat.addWebMessageListener(webView, LinkBridge.JS_OBJECT_NAME, allowList.rules, bridge)
            }
        } catch (e: IllegalArgumentException) {
            finishWithError(LinkError.INTERNAL, "Invalid allowed origin: ${e.message}")
            return
        }
        this.bridge = bridge

        setContentView(buildLayout(webView))
        Log.i(TAG, "opening $action; bridge origin: ${destination.origin}")
        // §2 step 4: the host's callback runs while the page loads.
        bridge.prefetchClientSecret()
        webView.loadUrl(destination.url)
    }

    /**
     * The `fetchClientSecret` of the instance that opened this screen, called with the action it
     * opened with. When the instance is gone (Android recreated the screen after the app's process
     * died), the page gets `clientSecretUnavailable`.
     */
    private fun clientSecretSource(): suspend () -> String {
        Instances.clientSecretSource(instanceId)?.let { return it }
        Log.w(TAG, "the Plugchoice instance that opened this screen is gone (the app's process was restarted?)")
        return { throw IllegalStateException("the Plugchoice instance that opened this screen is gone") }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun configure(webView: WebView) {
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            setGeolocationEnabled(false)
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
        }
        webView.webViewClient = LinkWebViewClient()
        webView.webChromeClient = WebChromeClient() // console messages go to logcat
    }

    private fun buildLayout(webView: WebView): ViewGroup {
        val root = FrameLayout(this)
        root.setBackgroundColor(Color.WHITE)
        root.addView(webView, FrameLayout.LayoutParams(MATCH, MATCH))
        root.addView(buildLoadErrorView(), FrameLayout.LayoutParams(MATCH, MATCH))

        val size = dp(40)
        val margin = dp(12)
        val close = ImageButton(this).apply {
            setImageResource(R.drawable.plugchoice_link_ic_close)
            background = ContextCompat.getDrawable(context, R.drawable.plugchoice_link_close_background)
            scaleType = ImageView.ScaleType.CENTER
            contentDescription = getString(R.string.plugchoice_link_close)
            elevation = dp(2).toFloat()
            setOnClickListener { requestClose() }
        }
        closeButton = close
        root.addView(
            close,
            FrameLayout.LayoutParams(size, size, Gravity.TOP or Gravity.END).apply {
                setMargins(margin, margin, margin, margin)
            },
        )

        // Edge-to-edge (enforced from Android 15): keep the page and button out of the system bars,
        // cutouts and the keyboard.
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val bars = insets.getInsets(
                WindowInsetsCompat.Type.systemBars() or
                    WindowInsetsCompat.Type.displayCutout() or
                    WindowInsetsCompat.Type.ime(),
            )
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            WindowInsetsCompat.CONSUMED
        }
        return root
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        bridge?.onWindowFocusChanged(hasFocus)
    }

    override fun onDestroy() {
        bridge?.dispose()
        bridge = null
        destroyWebView()
        pendingPermissions?.cancel()
        // Not when Android recreates the screen: the new one needs the instance too.
        if (isFinishing) instanceId?.let(Instances::release)
        super.onDestroy()
    }

    private fun destroyWebView() {
        val webView = webView ?: return
        this.webView = null
        if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            WebViewCompat.removeWebMessageListener(webView, LinkBridge.JS_OBJECT_NAME)
        }
        webView.stopLoading()
        (webView.parent as? ViewGroup)?.removeView(webView)
        webView.destroy()
    }

    /**
     * Back and the native close button: the page decides after its `hello` (§6.2). On the
     * load-error screen there is no page: close at once with `pageLoadFailed`.
     */
    private fun requestClose() {
        val bridge = bridge
        val loadError = loadError
        when {
            loadError != null -> finishWith(errorResult(LinkError.PAGE_LOAD_FAILED, loadError))
            bridge != null && !finished -> bridge.requestClose()
            else -> finishWith(cancelledResult())
        }
    }

    /** "The page did not load" with "Try again", over the web view and under the close button. */
    private fun buildLoadErrorView(): View {
        val title = TextView(this).apply {
            setTextAppearance(android.R.style.TextAppearance_Material_Title)
            text = getString(R.string.plugchoice_link_load_error_title)
            gravity = Gravity.CENTER
        }
        val detail = TextView(this).apply {
            setTextAppearance(android.R.style.TextAppearance_Material_Caption)
            gravity = Gravity.CENTER
            setPadding(0, dp(12), 0, dp(16))
        }
        loadErrorDetail = detail
        val retry = Button(this).apply {
            text = getString(R.string.plugchoice_link_try_again)
            setOnClickListener { retryLoad() }
        }
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(32), 0, dp(32), 0)
            addView(title, LinearLayout.LayoutParams(MATCH, WRAP))
            addView(detail, LinearLayout.LayoutParams(MATCH, WRAP))
            addView(retry, LinearLayout.LayoutParams(WRAP, WRAP))
        }
        return FrameLayout(this).apply {
            setBackgroundColor(Color.WHITE)
            visibility = View.GONE
            // Swallow touches so the web view underneath stays out of reach.
            isClickable = true
            addView(content, FrameLayout.LayoutParams(MATCH, WRAP, Gravity.CENTER))
            loadErrorView = this
        }
    }

    /** The main frame failed to load: no page, so the native close button closes at once. */
    private fun showLoadError(description: String) {
        loadError = "Could not load the Link UI: $description"
        bridge?.onNewDocument()
        // The origin only, not the whole URL.
        loadErrorDetail?.text =
            getString(R.string.plugchoice_link_load_error_detail, destination?.origin.orEmpty(), description)
        loadErrorView?.visibility = View.VISIBLE
    }

    private fun retryLoad() {
        val url = destination?.url ?: return
        loadError = null
        loadErrorView?.visibility = View.GONE
        webView?.loadUrl(url)
    }

    /** §6.3: the shell's own results carry the action it opened, no session and no devices. */
    private fun cancelledResult(): LinkResult = LinkResult(LinkResult.Status.CANCELLED, action)

    private fun errorResult(code: String, message: String): LinkResult =
        LinkResult(LinkResult.Status.ERROR, action, error = LinkError(code, message))

    private fun finishWithError(code: String, message: String) {
        Log.w(TAG, message)
        finishWith(errorResult(code, message))
    }

    private fun finishWith(result: LinkResult) {
        if (finished) return
        finished = true
        Log.i(TAG, "closing with ${result.status.value}")
        // Leave the charger network right away rather than when onDestroy comes around.
        bridge?.dispose()
        setResult(RESULT_OK, LinkIntents.resultIntent(result, instanceId))
        finish()
    }

    private fun dp(value: Int): Int =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value.toFloat(), resources.displayMetrics).toInt()

    private inner class LinkWebViewClient : WebViewClient() {

        /**
         * The main frame stays on the allowed origin. Elsewhere, a link the user tapped opens
         * outside (as on iOS); anything else (a redirect, a script) is dropped. Subframes load (the
         * bridge ignores them).
         */
        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            if (!request.isForMainFrame) return false
            val uri = request.url
            if (origins?.allows(uri) == true) return false
            if (request.hasGesture()) openExternally(uri) else Log.w(TAG, "blocked a navigation off the allowed origin")
            return true
        }

        override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
            bridge?.onNewDocument()
        }

        override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
            // A document that didn't load (server unreachable, no internet): offer "Try again".
            // Subresource errors are the page's own business.
            if (request.isForMainFrame && !finished) {
                Log.w(TAG, "the Link UI did not load: ${error.description} (${error.errorCode})")
                showLoadError("${error.description} (${error.errorCode})")
            }
        }

        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            Log.e(TAG, "WebView renderer gone (crashed: ${detail.didCrash()})")
            bridge?.dispose()
            bridge = null
            destroyWebView()
            finishWithError(LinkError.INTERNAL, "The Link UI stopped (WebView renderer gone)")
            return true
        }
    }

    private fun openExternally(uri: Uri) {
        if (uri.scheme?.lowercase() !in EXTERNAL_SCHEMES) {
            Log.w(TAG, "blocked navigation to $uri")
            return
        }
        try {
            startActivity(Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE))
        } catch (_: ActivityNotFoundException) {
            Log.w(TAG, "no app to open $uri")
        }
    }

    private companion object {
        const val TAG = "Plugchoice"
        const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT

        /** What a tapped link off the allowed origin may open outside the app. */
        val EXTERNAL_SCHEMES = setOf("http", "https", "mailto", "tel")
    }
}
