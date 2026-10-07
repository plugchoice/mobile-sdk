package com.plugchoice

/**
 * What the Link screen opens for: an action, and the charger or site it is about.
 *
 * ```kotlin
 * LinkAction.addCharger()                 // add a charger
 * LinkAction.addCharger(siteId)           // add a charger at a site
 * LinkAction.network(chargerId)           // change a charger's network (Wi-Fi)
 * LinkAction.setup(chargerId)             // set a charger up
 * LinkAction.reconnect(chargerId)         // reconnect a charger to Plugchoice
 * LinkAction.custom("later-action", chargerId)
 * ```
 *
 * The SDK passes the action to the page without reading it, so an action the page learns later
 * works through [custom] before it gets a helper here. Empty ids are left out.
 *
 * @property name The action, for example `"add"` or `"network"`.
 */
public class LinkAction private constructor(
    public val name: String,
    public val chargerId: String?,
    public val siteId: String?,
) {
    override fun equals(other: Any?): Boolean =
        other is LinkAction && other.name == name && other.chargerId == chargerId && other.siteId == siteId

    override fun hashCode(): Int = (name.hashCode() * 31 + chargerId.hashCode()) * 31 + siteId.hashCode()

    override fun toString(): String = "LinkAction(name=$name, chargerId=$chargerId, siteId=$siteId)"

    public companion object {
        public const val ADD: String = "add"
        public const val NETWORK: String = "network"
        public const val SETUP: String = "setup"
        public const val RECONNECT: String = "reconnect"

        /** Add a charger, optionally at the site [siteId]. */
        @JvmStatic
        @JvmOverloads
        public fun addCharger(siteId: String? = null): LinkAction = of(ADD, chargerId = null, siteId = siteId)

        /** Change the network (Wi-Fi) of the charger [chargerId]. */
        @JvmStatic
        public fun network(chargerId: String): LinkAction = of(NETWORK, chargerId, siteId = null)

        /** Set up the charger [chargerId]. */
        @JvmStatic
        public fun setup(chargerId: String): LinkAction = of(SETUP, chargerId, siteId = null)

        /** Reconnect the charger [chargerId] to Plugchoice. */
        @JvmStatic
        public fun reconnect(chargerId: String): LinkAction = of(RECONNECT, chargerId, siteId = null)

        /**
         * Any action by its name, for actions without a helper yet.
         *
         * @throws IllegalArgumentException when [action] is blank.
         */
        @JvmStatic
        @JvmOverloads
        public fun custom(action: String, chargerId: String? = null, siteId: String? = null): LinkAction {
            require(action.isNotBlank()) { "action must not be blank" }
            return of(action, chargerId, siteId)
        }

        private fun of(action: String, chargerId: String?, siteId: String?) =
            LinkAction(action, chargerId?.takeIf { it.isNotEmpty() }, siteId?.takeIf { it.isNotEmpty() })
    }
}
