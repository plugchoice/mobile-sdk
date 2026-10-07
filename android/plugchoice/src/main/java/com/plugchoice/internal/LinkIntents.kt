package com.plugchoice.internal

import android.content.Context
import android.content.Intent
import com.plugchoice.Device
import com.plugchoice.LinkAction
import com.plugchoice.LinkError
import com.plugchoice.LinkResult

/** The extras of the intent that opens the Link screen and of the result it hands back. */
internal object LinkIntents {
    private const val EXTRA_INSTANCE = "com.plugchoice.INSTANCE"
    private const val EXTRA_ACTION = "com.plugchoice.ACTION"
    private const val EXTRA_CHARGER_ID = "com.plugchoice.CHARGER_ID"
    private const val EXTRA_SITE_ID = "com.plugchoice.SITE_ID"
    private const val EXTRA_HOST_OVERRIDE = "com.plugchoice.HOST_OVERRIDE"
    private const val EXTRA_STATUS = "com.plugchoice.STATUS"
    private const val EXTRA_RESULT_ACTION = "com.plugchoice.RESULT_ACTION"
    private const val EXTRA_SESSION_ID = "com.plugchoice.SESSION_ID"
    private const val EXTRA_DEVICE_TYPES = "com.plugchoice.DEVICE_TYPES"
    private const val EXTRA_DEVICE_IDS = "com.plugchoice.DEVICE_IDS"
    private const val EXTRA_ERROR_CODE = "com.plugchoice.ERROR_CODE"
    private const val EXTRA_ERROR_MESSAGE = "com.plugchoice.ERROR_MESSAGE"

    /** No secret goes in: the screen asks the instance [instanceId] for it. */
    fun open(context: Context, action: LinkAction, instanceId: String, hostOverride: String?): Intent =
        Intent(context, LinkActivity::class.java)
            .putExtra(EXTRA_INSTANCE, instanceId)
            .putExtra(EXTRA_ACTION, action.name)
            .putExtra(EXTRA_CHARGER_ID, action.chargerId)
            .putExtra(EXTRA_SITE_ID, action.siteId)
            .putExtra(EXTRA_HOST_OVERRIDE, hostOverride)

    fun instanceId(intent: Intent): String? = intent.getStringExtra(EXTRA_INSTANCE)

    fun hostOverride(intent: Intent): String? = intent.getStringExtra(EXTRA_HOST_OVERRIDE)

    /** The action an intent from [open] carries; null when it has none. */
    fun action(intent: Intent): LinkAction? {
        val name = intent.getStringExtra(EXTRA_ACTION)?.takeIf { it.isNotBlank() } ?: return null
        return LinkAction.custom(name, intent.getStringExtra(EXTRA_CHARGER_ID), intent.getStringExtra(EXTRA_SITE_ID))
    }

    fun resultIntent(result: LinkResult, instanceId: String?): Intent =
        Intent()
            .putExtra(EXTRA_INSTANCE, instanceId)
            .putExtra(EXTRA_STATUS, result.status.value)
            .putExtra(EXTRA_RESULT_ACTION, result.action)
            .putExtra(EXTRA_SESSION_ID, result.sessionId)
            .putStringArrayListExtra(EXTRA_DEVICE_TYPES, ArrayList(result.devices.map { it.type }))
            .putStringArrayListExtra(EXTRA_DEVICE_IDS, ArrayList(result.devices.map { it.id }))
            .putExtra(EXTRA_ERROR_CODE, result.error?.code)
            .putExtra(EXTRA_ERROR_MESSAGE, result.error?.message)

    /** Reads [resultIntent]; anything unexpected reads as cancelled. */
    fun result(data: Intent, fallbackAction: String): LinkResult {
        val action = data.getStringExtra(EXTRA_RESULT_ACTION) ?: fallbackAction
        val sessionId = data.getStringExtra(EXTRA_SESSION_ID)
        val status = LinkResult.Status.fromValue(data.getStringExtra(EXTRA_STATUS))
            ?: return LinkResult(LinkResult.Status.CANCELLED, action, sessionId)
        val types = data.getStringArrayListExtra(EXTRA_DEVICE_TYPES).orEmpty()
        val ids = data.getStringArrayListExtra(EXTRA_DEVICE_IDS).orEmpty()
        return LinkResult(
            status = status,
            action = action,
            sessionId = sessionId,
            devices = types.zip(ids) { type, id -> Device(type, id) },
            error = data.getStringExtra(EXTRA_ERROR_CODE)?.let { LinkError(it, data.getStringExtra(EXTRA_ERROR_MESSAGE)) },
        )
    }
}
