package com.plugchoice.internal

import android.content.Context
import com.plugchoice.LinkResult

/** What the bridge needs from the activity hosting it. All calls happen on the main thread. */
internal interface BridgeHost {
    /** The activity (the code scanner starts from it). */
    val hostContext: Context

    /** Runtime permission request through the activity; returns permission → granted. */
    suspend fun requestPermissions(permissions: Array<String>): Map<String, Boolean>

    /** `session.close`, or the shell closing on its own: dismiss the Link screen and hand [result] to the host app. */
    fun closeSession(result: LinkResult)

    /** Hide the native close button once a page that draws its own answered `hello`; show it again for a new page. */
    fun setNativeCloseButtonVisible(visible: Boolean)
}
