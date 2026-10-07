package com.plugchoice.internal

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.Base64

/** Bluetooth without a radio (PROTOCOL.md §11): UUIDs, advertisements, scan results and `ble.*` params. */
class BleModelTest {

    private fun assertCode(code: String, body: () -> Unit) {
        try {
            body()
            fail("expected $code")
        } catch (e: BridgeException) {
            assertEquals(code, e.code)
        }
    }

    private fun json(vararg pairs: Pair<String, Any?>) = JSONObject().apply { for ((key, value) in pairs) put(key, value) }

    private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }

    // UUIDs

    @Test
    fun `UUIDs are answered in full and lower case`() {
        assertEquals("0000a002-0000-1000-8000-00805f9b34fb", BleUuids.normalize("a002"))
        assertEquals("0000a002-0000-1000-8000-00805f9b34fb", BleUuids.normalize("A002"))
        assertEquals("1234a002-0000-1000-8000-00805f9b34fb", BleUuids.normalize("1234a002"))
        assertEquals("6e400001-b5a3-f393-e0a9-e50e24dcca9e", BleUuids.normalize("6E400001-B5A3-F393-E0A9-E50E24DCCA9E"))
        assertEquals("0000180f-0000-1000-8000-00805f9b34fb", BleUuids.normalize("180F"))
        assertNull("no whitespace around it (as on iOS)", BleUuids.normalize(" 180F "))
    }

    @Test
    fun `what is not a UUID`() {
        for (bad in listOf("", "a0", "a00", "a0020", "xyz1", "0000a002-0000-1000-8000", "6e400001b5a3f393e0a9e50e24dcca9e", "6e400001-b5a3-f393-e0a9-e50e24dcca9g", "{6e400001-b5a3-f393-e0a9-e50e24dcca9e}")) {
            assertNull(bad, BleUuids.normalize(bad))
        }
    }

    @Test
    fun `UUIDs from advertisement bytes are little-endian`() {
        assertEquals("0000180f-0000-1000-8000-00805f9b34fb", BleUuids.fromShort(bytes(0x0f, 0x18)))
        assertEquals("12345678-0000-1000-8000-00805f9b34fb", BleUuids.fromShort(bytes(0x78, 0x56, 0x34, 0x12)))
        val nordicUart = bytes(0x9e, 0xca, 0xdc, 0x24, 0x0e, 0xe5, 0xa9, 0xe0, 0x93, 0xf3, 0xa3, 0xb5, 0x01, 0x00, 0x40, 0x6e)
        assertEquals("6e400001-b5a3-f393-e0a9-e50e24dcca9e", BleUuids.fromLong(nordicUart))
    }

    // Advertisements

    private val nordicUartLe = intArrayOf(0x9e, 0xca, 0xdc, 0x24, 0x0e, 0xe5, 0xa9, 0xe0, 0x93, 0xf3, 0xa3, 0xb5, 0x01, 0x00, 0x40, 0x6e)

    private fun advertisement(): ByteArray = bytes(
        0x02, 0x01, 0x06, // flags
        0x05, 0x03, 0x0f, 0x18, 0x0a, 0x18, // complete 16-bit UUIDs: 180f, 180a
        0x11, 0x07, *nordicUartLe, // complete 128-bit UUIDs
        0x05, 0x08, 'O'.code, 'n'.code, 'e'.code, '-'.code, // short name "One-"
        0x0c, 0x09, *"One-AB12CD3".map { it.code }.toIntArray(), // complete name
        0x06, 0xff, 0x59, 0x00, 0x01, 0x02, 0x03, // manufacturer 0x0059 (Nordic): 01 02 03
        0x04, 0xff, 0x4c, 0x00, 0x09, // manufacturer 0x004c: 09
        0x05, 0x16, 0x0f, 0x18, 0x64, 0x00, // service data 180f: 64 00
        0x00, 0x00, 0x00, // padding
    )

    @Test
    fun `an advertisement's fields`() {
        val parsed = BleAdvertisement.parse(advertisement())
        assertEquals("the complete name wins", "One-AB12CD3", parsed.localName)
        assertEquals(
            listOf("0000180f-0000-1000-8000-00805f9b34fb", "0000180a-0000-1000-8000-00805f9b34fb", "6e400001-b5a3-f393-e0a9-e50e24dcca9e"),
            parsed.serviceUuids,
        )
        assertEquals(listOf(0x0059, 0x004c), parsed.manufacturerData.map { it.first })
        assertArrayEquals("without the company id", bytes(1, 2, 3), parsed.manufacturerData[0].second)
        assertEquals("0000180f-0000-1000-8000-00805f9b34fb", parsed.serviceData.single().first)
        assertArrayEquals(bytes(0x64, 0x00), parsed.serviceData.single().second)
    }

    @Test
    fun `a short name when there is no complete one`() {
        assertEquals("One-", BleAdvertisement.parse(bytes(0x05, 0x08, 'O'.code, 'n'.code, 'e'.code, '-'.code)).localName)
    }

    @Test
    fun `malformed advertisements keep what came before`() {
        val truncated = bytes(0x03, 0x03, 0x0f, 0x18, 0x09, 0xff, 0x59, 0x00)
        val parsed = BleAdvertisement.parse(truncated)
        assertEquals(listOf("0000180f-0000-1000-8000-00805f9b34fb"), parsed.serviceUuids)
        assertTrue(parsed.manufacturerData.isEmpty())
        assertTrue(BleAdvertisement.parse(null).serviceUuids.isEmpty())
        assertTrue(BleAdvertisement.parse(ByteArray(0)).manufacturerData.isEmpty())
        // A manufacturer entry too short for a company id, and a partial UUID, are skipped.
        val short = BleAdvertisement.parse(bytes(0x02, 0xff, 0x59, 0x04, 0x03, 0x0f, 0x18, 0x0a))
        assertTrue(short.manufacturerData.isEmpty())
        assertEquals(listOf("0000180f-0000-1000-8000-00805f9b34fb"), short.serviceUuids)
    }

    // Scan results

    private fun device(results: JSONArray, i: Int) = results.getJSONObject(i)

    @Test
    fun `each device once, with its latest RSSI and name`() {
        val results = BleScanResults(stopOnName = null)
        assertFalse(results.add("AA:BB:CC:DD:EE:01", null, -80, BleAdvertisement.EMPTY, true))
        results.add("AA:BB:CC:DD:EE:02", "Other", -60, BleAdvertisement.EMPTY, null)
        results.add("AA:BB:CC:DD:EE:01", null, -70, BleAdvertisement.parse(advertisement()), true)
        results.add("AA:BB:CC:DD:EE:01", "cached", -65, BleAdvertisement.EMPTY, null)
        val json = results.toJson()
        assertEquals(2, json.length())
        val one = device(json, 0)
        assertEquals("AA:BB:CC:DD:EE:01", one.getString("deviceId"))
        assertEquals("the latest name: the cached one without an advertised name", "cached", one.getString("name"))
        assertEquals(-65, one.getInt("rssi"))
        assertEquals(3, one.getJSONArray("serviceUuids").length())
        assertTrue(one.getBoolean("connectable"))
        val manufacturer = one.getJSONArray("manufacturerData").getJSONObject(0)
        assertEquals(0x0059, manufacturer.getInt("companyId"))
        assertEquals(Base64.getEncoder().encodeToString(bytes(1, 2, 3)), manufacturer.getString("data"))
        assertEquals("0000180f-0000-1000-8000-00805f9b34fb", one.getJSONArray("serviceData").getJSONObject(0).getString("uuid"))
        val other = device(json, 1)
        assertEquals(JSONObject.NULL, other.get("connectable"))
        assertEquals(0, other.getJSONArray("manufacturerData").length())
    }

    @Test
    fun `a nameless device answers name null`() {
        val results = BleScanResults(null)
        results.add("AA:BB:CC:DD:EE:01", null, -80, BleAdvertisement.EMPTY, false)
        assertEquals(JSONObject.NULL, device(results.toJson(), 0).get("name"))
    }

    @Test
    fun `stopOnName stops on a lower-cased substring of the name`() {
        val results = BleScanResults(stopOnName = "ab12cd3")
        assertFalse(results.add("AA:BB:CC:DD:EE:02", "One-FFFFFF0", -60, BleAdvertisement.EMPTY, true))
        assertFalse(results.add("AA:BB:CC:DD:EE:01", null, -60, BleAdvertisement.EMPTY, true))
        assertTrue(results.add("AA:BB:CC:DD:EE:01", null, -60, BleAdvertisement.parse(advertisement()), true))
        assertEquals("everything seen so far", 2, results.size)
    }

    // Params

    @Test
    fun `scan params`() {
        val scan = BleRequests.scan(json("services" to JSONArray(listOf("a002", "A002", "6e400001-b5a3-f393-e0a9-e50e24dcca9e")), "timeoutMs" to 8000, "stopOnName" to "One"))
        assertEquals(listOf("0000a002-0000-1000-8000-00805f9b34fb", "6e400001-b5a3-f393-e0a9-e50e24dcca9e"), scan.services)
        assertEquals(8000L, scan.timeoutMs)
        assertEquals("One", scan.stopOnName)
        assertNull("an empty stopOnName is none", BleRequests.scan(json("timeoutMs" to 8000, "stopOnName" to "")).stopOnName)
        val all = BleRequests.scan(json("timeoutMs" to 100))
        assertTrue("no services: every device", all.services.isEmpty())
        assertEquals("at least 1 s", 1_000L, all.timeoutMs)
        assertEquals("at most 60 s", 60_000L, BleRequests.scan(json("timeoutMs" to 600_000)).timeoutMs)
        for (bad in listOf(json(), json("timeoutMs" to 0), json("timeoutMs" to 1000, "services" to "a002"), json("timeoutMs" to 1000, "services" to JSONArray().put("nope")), json("timeoutMs" to 1000, "stopOnName" to 1))) {
            assertCode(ErrorCode.INVALID_PARAMS) { BleRequests.scan(bad) }
        }
    }

    @Test
    fun `connect params`() {
        val connect = BleRequests.connect(json("deviceId" to "AA:BB:CC:DD:EE:01", "timeoutMs" to 15000))
        assertEquals("AA:BB:CC:DD:EE:01", connect.deviceId)
        assertEquals(15_000L, connect.timeoutMs)
        assertEquals("247 unless asked", 247, connect.mtu)
        assertEquals(517, BleRequests.connect(json("deviceId" to "x", "timeoutMs" to 1, "mtu" to 517)).mtu)
        for (bad in listOf(
            json("timeoutMs" to 1000),
            json("deviceId" to "", "timeoutMs" to 1000),
            json("deviceId" to "x"),
            json("deviceId" to "x", "timeoutMs" to -1),
            json("deviceId" to "x", "timeoutMs" to 1000, "mtu" to 22),
            json("deviceId" to "x", "timeoutMs" to 1000, "mtu" to 518),
            json("deviceId" to "x", "timeoutMs" to 1000, "mtu" to 100.5),
        )) {
            assertCode(ErrorCode.INVALID_PARAMS) { BleRequests.connect(bad) }
        }
    }

    @Test
    fun `characteristic params`() {
        val target = BleRequests.characteristic(json("deviceId" to "x", "service" to "a002", "characteristic" to "C302"))
        assertEquals("0000a002-0000-1000-8000-00805f9b34fb", target.service)
        assertEquals("0000c302-0000-1000-8000-00805f9b34fb", target.characteristic)
        for (bad in listOf(
            json("service" to "a002", "characteristic" to "c302"),
            json("deviceId" to "x", "characteristic" to "c302"),
            json("deviceId" to "x", "service" to "a002"),
            json("deviceId" to "x", "service" to "nope", "characteristic" to "c302"),
            json("deviceId" to "x", "service" to "a002", "characteristic" to 302),
        )) {
            assertCode(ErrorCode.INVALID_PARAMS) { BleRequests.characteristic(bad) }
        }
    }

    @Test
    fun `write params`() {
        val base = json("deviceId" to "x", "service" to "a002", "characteristic" to "c302")
        val write = BleRequests.write(JSONObject(base.toString()).put("value", Base64.getEncoder().encodeToString(ByteArray(512))).put("withResponse", true))
        assertEquals("a long write, up to 512 bytes", 512, write.value.size)
        assertTrue(write.withResponse)
        assertEquals(0, BleRequests.write(JSONObject(base.toString()).put("value", "").put("withResponse", false)).value.size)
        for ((value, withResponse) in listOf<Pair<Any?, Any?>>(
            Base64.getEncoder().encodeToString(ByteArray(513)) to true,
            "not base64!" to true,
            null to true,
            "AA==" to null,
            "AA==" to "true",
        )) {
            val bad = JSONObject(base.toString()).apply {
                if (value != null) put("value", value)
                if (withResponse != null) put("withResponse", withResponse)
            }
            assertCode(ErrorCode.INVALID_PARAMS) { BleRequests.write(bad) }
        }
    }
}
