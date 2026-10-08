package com.plugchoice.example

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.Spinner
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContract
import androidx.core.content.edit
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.plugchoice.LinkAction
import com.plugchoice.LinkResult
import com.plugchoice.Plugchoice
import java.text.DateFormat
import java.util.Date

/**
 * A client secret field, a Link UI host field (the debug host override), an action picker with
 * the charger and site ids, "Open", and the last result. The fields are remembered.
 *
 * A real app creates one [Plugchoice] whose `fetchClientSecret` asks its own server for a client
 * secret scoped to the action it gets (`POST /sdk/v1/client-sessions` on the server's side). Here
 * the callback answers whatever is in the client secret field and shows the action it was asked
 * for, and a new instance is made when the host field changes (the override is an instance
 * option), so the launcher asks the current instance for its contract.
 * The override only works because this is a debug build.
 */
class MainActivity : ComponentActivity() {

    private val prefs by lazy { getSharedPreferences(PREFS, Context.MODE_PRIVATE) }
    private lateinit var secretField: EditText
    private lateinit var hostField: EditText
    private lateinit var actionPicker: Spinner
    private lateinit var customActionField: EditText
    private lateinit var chargerIdField: EditText
    private lateinit var siteIdField: EditText
    private lateinit var resultView: TextView

    /** The secret the page gets: the field's value when Open was tapped. */
    private var clientSecret = ""
    private lateinit var secretRequestView: TextView
    private var plugchoice = newPlugchoice(hostOverride = null)

    private val openLink = registerForActivityResult(
        object : ActivityResultContract<LinkAction, LinkResult>() {
            private var contract = plugchoice.link.contract()

            override fun createIntent(context: Context, input: LinkAction): Intent {
                contract = plugchoice.link.contract()
                return contract.createIntent(context, input)
            }

            override fun parseResult(resultCode: Int, intent: Intent?): LinkResult = contract.parseResult(resultCode, intent)
        },
    ) { result -> showResult(result) }

    private fun newPlugchoice(hostOverride: String?) = Plugchoice(
        // A real app: `{ action -> backend.plugchoiceClientSecret(action) }`, its server scoping the
        // client session to action.name and action.chargerId or action.siteId.
        fetchClientSecret = { action ->
            secretRequestView.text = getString(R.string.secret_requested, describe(action), DateFormat.getTimeInstance().format(Date()))
            clientSecret
        },
        options = Plugchoice.Options(hostOverride = hostOverride),
    )

    private fun describe(action: LinkAction): String = buildString {
        append(action.name)
        action.chargerId?.let { append(", charger ").append(it) }
        action.siteId?.let { append(", site ").append(it) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        val root = findViewById<View>(R.id.root)
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val bars = insets.getInsets(
                WindowInsetsCompat.Type.systemBars() or
                    WindowInsetsCompat.Type.displayCutout() or
                    WindowInsetsCompat.Type.ime(),
            )
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            WindowInsetsCompat.CONSUMED
        }

        secretField = findViewById(R.id.client_secret)
        hostField = findViewById(R.id.host)
        actionPicker = findViewById(R.id.action)
        customActionField = findViewById(R.id.custom_action)
        chargerIdField = findViewById(R.id.charger_id)
        siteIdField = findViewById(R.id.site_id)
        resultView = findViewById(R.id.result)
        secretRequestView = findViewById(R.id.secret_request)

        actionPicker.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, ACTIONS)
        actionPicker.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
                customActionField.visibility = if (ACTIONS[position] == CUSTOM) View.VISIBLE else View.GONE
            }

            override fun onNothingSelected(parent: AdapterView<*>?) {}
        }

        secretField.setText(prefs.getString(KEY_SECRET, ""))
        hostField.setText(prefs.getString(KEY_HOST, ""))
        actionPicker.setSelection(ACTIONS.indexOf(prefs.getString(KEY_ACTION, LinkAction.ADD)).coerceAtLeast(0))
        customActionField.setText(prefs.getString(KEY_CUSTOM_ACTION, ""))
        chargerIdField.setText(prefs.getString(KEY_CHARGER_ID, ""))
        siteIdField.setText(prefs.getString(KEY_SITE_ID, ""))
        prefs.getString(KEY_RESULT, null)?.let { resultView.text = it }
        findViewById<TextView>(R.id.transports).text =
            getString(R.string.transports, Plugchoice.transports(this).joinToString(", "))

        findViewById<Button>(R.id.open).setOnClickListener { open() }

        // Testing aid, like the iOS example's `-autoOpen`:
        // `adb shell am start -n com.plugchoice.example/.MainActivity --es clientSecret cs_… \
        //   --es host 10.0.2.2:5173 --es action reconnect --es chargerId 42 --ez autoOpen true`
        if (savedInstanceState == null) {
            intent.getStringExtra(EXTRA_CLIENT_SECRET)?.let(secretField::setText)
            intent.getStringExtra(EXTRA_HOST)?.let(hostField::setText)
            intent.getStringExtra(EXTRA_ACTION)?.let { action ->
                if (action in ACTIONS) {
                    actionPicker.setSelection(ACTIONS.indexOf(action))
                } else {
                    actionPicker.setSelection(ACTIONS.indexOf(CUSTOM))
                    customActionField.setText(action)
                }
            }
            intent.getStringExtra(EXTRA_CHARGER_ID)?.let(chargerIdField::setText)
            intent.getStringExtra(EXTRA_SITE_ID)?.let(siteIdField::setText)
            if (intent.getBooleanExtra(EXTRA_AUTO_OPEN, false)) open()
        }
    }

    private fun open() {
        val secret = secretField.text.toString().trim()
        val host = hostField.text.toString().trim()
        val override = when {
            host.isEmpty() -> null
            host.contains("://") -> host
            else -> "http://$host" // `192.168.1.20:5173` is enough
        }
        val action = linkAction() ?: run {
            customActionField.error = getString(R.string.custom_action_missing)
            return
        }
        prefs.edit {
            putString(KEY_SECRET, secret)
            putString(KEY_HOST, host)
            putString(KEY_ACTION, ACTIONS[actionPicker.selectedItemPosition])
            putString(KEY_CUSTOM_ACTION, customActionField.text.toString().trim())
            putString(KEY_CHARGER_ID, chargerIdField.text.toString().trim())
            putString(KEY_SITE_ID, siteIdField.text.toString().trim())
        }
        clientSecret = secret
        if (plugchoice.options.hostOverride != override) plugchoice = newPlugchoice(override)
        openLink.launch(action)
    }

    private fun linkAction(): LinkAction? {
        val chargerId = chargerIdField.text.toString().trim()
        val siteId = siteIdField.text.toString().trim().ifEmpty { null }
        return when (val name = ACTIONS[actionPicker.selectedItemPosition]) {
            LinkAction.ADD -> LinkAction.addCharger(siteId)
            LinkAction.SETUP -> LinkAction.setup(chargerId)
            LinkAction.RECONNECT -> LinkAction.reconnect(chargerId)
            else -> customActionField.text.toString().trim().takeIf { it.isNotEmpty() && name == CUSTOM }
                ?.let { LinkAction.custom(it, chargerId, siteId) }
        }
    }

    private fun showResult(result: LinkResult) {
        val text = buildString {
            append("status:  ").append(result.status.value).append('\n')
            append("action:  ").append(result.action.ifEmpty { "none" }).append('\n')
            append("session: ").append(result.sessionId ?: "none").append('\n')
            append("devices: ").append(result.devices.joinToString { "${it.type} ${it.id}" }.ifEmpty { "none" }).append('\n')
            result.error?.let { error ->
                append("error:   ").append(error.code)
                error.message?.let { append(": ").append(it) }
                append('\n')
            }
            append("at:      ").append(DateFormat.getDateTimeInstance().format(Date()))
        }
        resultView.text = text
        prefs.edit { putString(KEY_RESULT, text) }
    }

    private companion object {
        const val PREFS = "plugchoice-example"
        const val KEY_SECRET = "clientSecret"
        const val KEY_HOST = "host"
        const val KEY_ACTION = "action"
        const val KEY_CUSTOM_ACTION = "customAction"
        const val KEY_CHARGER_ID = "chargerId"
        const val KEY_SITE_ID = "siteId"
        const val KEY_RESULT = "lastResult"

        const val EXTRA_CLIENT_SECRET = "clientSecret"
        const val EXTRA_HOST = "host"
        const val EXTRA_ACTION = "action"
        const val EXTRA_CHARGER_ID = "chargerId"
        const val EXTRA_SITE_ID = "siteId"
        const val EXTRA_AUTO_OPEN = "autoOpen"

        const val CUSTOM = "custom…"
        val ACTIONS = listOf(LinkAction.ADD, LinkAction.SETUP, LinkAction.RECONNECT, CUSTOM)
    }
}
