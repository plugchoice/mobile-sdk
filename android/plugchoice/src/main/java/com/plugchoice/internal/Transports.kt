package com.plugchoice.internal

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build

/**
 * What this device and app can do (`Plugchoice.transports`), and whether `hello` lists `ble`
 * (PROTOCOL.md §5). No prompts: only features and the app's declared permissions.
 */
internal object Transports {
    const val WIFI = "wifi"
    const val HTTP = "http"
    const val SOCKET = "socket"
    const val LAN = "lan"
    const val BLE = "ble"

    fun available(context: Context): List<String> = buildList {
        if (context.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI)) add(WIFI)
        add(HTTP)
        add(SOCKET)
        add(LAN)
        if (bluetoothAvailable(context)) add(BLE)
    }

    /**
     * The device has Bluetooth LE and the app still declares the Bluetooth permissions the library
     * merges into its manifest (a host can remove them with `tools:node="remove"`).
     */
    fun bluetoothAvailable(context: Context): Boolean {
        if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) return false
        val declared = declaredPermissions(context)
        return bluetoothPermissions(context).all { it in declared }
    }

    /**
     * Android 12+ (for an app targeting it): `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT`. Before:
     * `BLUETOOTH` and `BLUETOOTH_ADMIN` (install time) and precise location (to scan).
     */
    fun bluetoothPermissions(context: Context): List<String> =
        if (usesNearbyDevicePermissions(context)) {
            listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            @Suppress("DEPRECATION")
            listOf(Manifest.permission.BLUETOOTH, Manifest.permission.BLUETOOTH_ADMIN, Manifest.permission.ACCESS_FINE_LOCATION)
        }

    /** The runtime part of [bluetoothPermissions]. */
    fun bluetoothRuntimePermissions(context: Context): List<String> =
        if (usesNearbyDevicePermissions(context)) {
            listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    fun usesNearbyDevicePermissions(context: Context): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            context.applicationInfo.targetSdkVersion >= Build.VERSION_CODES.S

    private fun declaredPermissions(context: Context): Set<String> = try {
        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.packageManager.getPackageInfo(
                context.packageName,
                PackageManager.PackageInfoFlags.of(PackageManager.GET_PERMISSIONS.toLong()),
            )
        } else {
            @Suppress("DEPRECATION")
            context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
        }
        info.requestedPermissions?.toSet().orEmpty()
    } catch (_: PackageManager.NameNotFoundException) {
        emptySet()
    }
}
