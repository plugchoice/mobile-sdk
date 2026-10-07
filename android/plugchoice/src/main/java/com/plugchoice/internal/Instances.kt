package com.plugchoice.internal

import com.plugchoice.LinkAction
import com.plugchoice.Plugchoice
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * The [Plugchoice] instances behind open screens, each with the [LinkAction] its screen opened
 * with, so a screen (an activity, started by an intent) can call its instance's
 * `fetchClientSecret` with that action (PROTOCOL.md §2, §7). An intent carries the id; the
 * entry stays here until its screen has finished (or the result was read), and no longer.
 *
 * In-process only: after the process died and Android recreated the screen, the id finds nothing,
 * and the page gets `clientSecretUnavailable`.
 */
internal object Instances {
    class Entry(val plugchoice: Plugchoice, val action: LinkAction)

    private val registered = ConcurrentHashMap<String, Entry>()

    /** Registers [plugchoice] for one screen opened with [action]; the id goes into its intent. */
    fun register(plugchoice: Plugchoice, action: LinkAction): String =
        UUID.randomUUID().toString().also { registered[it] = Entry(plugchoice, action) }

    fun get(id: String?): Entry? = id?.let(registered::get)

    /** Idempotent. */
    fun release(id: String) {
        registered.remove(id)
    }

    /**
     * The screen [id]'s client secret source: its instance's `fetchClientSecret`, called with the
     * action the screen opened with, for the prefetch and every refresh. Null when the instance is
     * gone.
     */
    fun clientSecretSource(id: String?): (suspend () -> String)? {
        val entry = get(id) ?: return null
        return { entry.plugchoice.fetchClientSecret(entry.action) }
    }
}
