package com.plugchoice.internal

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.util.Base64

/**
 * One connected device (PROTOCOL.md §11) over a scripted [GattLink] on a virtual clock: the
 * connect flow and its timeout, reads, writes, subscriptions, notifications and disconnects.
 */
class BleConnectionTest {
    private val service = "0000a002-0000-1000-8000-00805f9b34fb"
    private val readable = "0000c301-0000-1000-8000-00805f9b34fb"
    private val writable = "0000c302-0000-1000-8000-00805f9b34fb"
    private val notifying = "0000c303-0000-1000-8000-00805f9b34fb"
    private val indicating = "0000c304-0000-1000-8000-00805f9b34fb"
    private val noCccd = "0000c305-0000-1000-8000-00805f9b34fb"

    private lateinit var scheduler: FakeScheduler
    private lateinit var link: FakeGattLink
    private lateinit var connection: BleConnection
    private val events = mutableListOf<Pair<String, JSONObject>>()
    private var closed = 0
    private val answers = mutableListOf<Result<JSONObject>>()

    @Before
    fun setUp() {
        answers.clear()
        events.clear()
        closed = 0
        scheduler = FakeScheduler()
        link = FakeGattLink(
            listOf(
                GattService(
                    service,
                    listOf(
                        GattCharacteristic(readable, BleConnection.PROPERTY_READ),
                        GattCharacteristic(writable, BleConnection.PROPERTY_WRITE or BleConnection.PROPERTY_WRITE_NO_RESPONSE),
                        GattCharacteristic(notifying, BleConnection.PROPERTY_NOTIFY or BleConnection.PROPERTY_INDICATE),
                        GattCharacteristic(indicating, BleConnection.PROPERTY_INDICATE),
                        GattCharacteristic(noCccd, BleConnection.PROPERTY_NOTIFY),
                    ),
                ),
            ),
            noCccd = setOf(noCccd),
        )
        connection = BleConnection("AA:BB:CC:DD:EE:01", scheduler, { event, params -> events += event to params }) { closed++ }
    }

    private fun code(result: Result<*>): String? = (result.exceptionOrNull() as? BridgeException)?.code

    private fun assertCode(code: String, body: () -> Unit) {
        try {
            body()
            fail("expected $code")
        } catch (e: BridgeException) {
            assertEquals(code, e.code)
        }
    }

    private fun connect(mtu: Int = 247, timeoutMs: Long = 10_000) {
        connection.start(link, timeoutMs, mtu, answers::add)
    }

    /** Connected, discovered and the MTU agreed. */
    private fun ready(agreedMtu: Int = 247): JSONObject {
        connect()
        connection.onConnectionStateChange(0, connected = true)
        connection.onServicesDiscovered(0)
        connection.onMtuChanged(agreedMtu, 0)
        return answers.removeAt(0).getOrThrow()
    }

    // Connecting

    @Test
    fun `connect discovers, asks for the MTU and answers the services`() {
        connect(mtu = 247)
        assertTrue(answers.isEmpty())
        connection.onConnectionStateChange(0, connected = true)
        assertEquals(listOf("discoverServices"), link.calls)
        connection.onServicesDiscovered(0)
        assertEquals(listOf("discoverServices", "requestMtu 247"), link.calls)
        connection.onMtuChanged(185, 0)
        val result = answers.single().getOrThrow()
        assertEquals(185, result.getInt("mtu"))
        assertEquals(182, result.getInt("maxWriteLength"))
        val characteristics = result.getJSONArray("services").getJSONObject(0).getJSONArray("characteristics")
        assertEquals(service, result.getJSONArray("services").getJSONObject(0).getString("uuid"))
        assertEquals(readable, characteristics.getJSONObject(0).getString("uuid"))
        assertEquals("[\"read\"]", characteristics.getJSONObject(0).getJSONArray("properties").toString())
        assertEquals("[\"write\",\"writeWithoutResponse\"]", characteristics.getJSONObject(1).getJSONArray("properties").toString())
        assertEquals("[\"notify\",\"indicate\"]", characteristics.getJSONObject(2).getJSONArray("properties").toString())
        assertTrue(connection.isReady)
        assertEquals("the connect timeout is cancelled", 0, scheduler.pendingCount)
    }

    @Test
    fun `without an MTU exchange the MTU stays 23`() {
        link.mtuStarts = false
        connect()
        connection.onConnectionStateChange(0, connected = true)
        connection.onServicesDiscovered(0)
        val result = answers.single().getOrThrow()
        assertEquals(23, result.getInt("mtu"))
        assertEquals(20, result.getInt("maxWriteLength"))
    }

    @Test
    fun `a refused MTU keeps what was agreed before`() {
        connect()
        connection.onConnectionStateChange(0, connected = true)
        connection.onMtuChanged(517, 0) // Android 14 negotiating by itself
        connection.onServicesDiscovered(0)
        connection.onMtuChanged(247, 4)
        assertEquals(517, answers.single().getOrThrow().getInt("mtu"))
    }

    @Test
    fun `connect times out`() {
        connect(timeoutMs = 5_000)
        connection.onConnectionStateChange(0, connected = true)
        scheduler.advanceBy(5_000)
        assertEquals(ErrorCode.TIMEOUT, code(answers.single()))
        assertTrue(link.closed)
        assertEquals(1, closed)
        assertTrue("no events for a connection that never opened", events.isEmpty())
    }

    @Test
    fun `failures while connecting`() {
        connect()
        connection.onConnectionStateChange(133, connected = false)
        assertEquals(ErrorCode.GATT, code(answers.single()))
        assertTrue(link.closed)

        setUp()
        connect()
        connection.onConnectionStateChange(0, connected = true)
        connection.onServicesDiscovered(129)
        assertEquals(ErrorCode.GATT, code(answers.single()))

        setUp()
        link.discoverStarts = false
        connect()
        connection.onConnectionStateChange(0, connected = true)
        assertEquals(ErrorCode.GATT, code(answers.single()))
        assertTrue(events.isEmpty())
    }

    @Test
    fun `ble disconnect while connecting fails the connect`() {
        connect()
        connection.disconnect()
        assertEquals(ErrorCode.NOT_CONNECTED, code(answers.single()))
        assertTrue(link.closed)
        assertTrue(events.isEmpty())
    }

    @Test
    fun `the state answers a second connect`() {
        val first = ready()
        assertEquals(first.toString(), connection.stateJson().toString())
    }

    // Reads, writes, subscriptions

    @Test
    fun `a read`() {
        ready()
        connection.read(service, readable, answers::add)
        assertEquals("read $service/$readable", link.calls.last())
        connection.onRead(service, readable, byteArrayOf(1, 2, 3), 0)
        assertEquals(Base64.getEncoder().encodeToString(byteArrayOf(1, 2, 3)), answers.single().getOrThrow().getString("value"))
    }

    @Test
    fun `a refused read is gatt`() {
        ready()
        connection.read(service, readable, answers::add)
        connection.onRead(service, readable, ByteArray(0), 5)
        val error = answers.single().exceptionOrNull() as BridgeException
        assertEquals(ErrorCode.GATT, error.code)
        assertTrue(error.message!!.contains("status 5"))
    }

    @Test
    fun `requests checked against the services`() {
        assertCode(ErrorCode.NOT_CONNECTED) { connection.read(service, readable) {} }
        ready()
        assertCode(ErrorCode.UNKNOWN_CHARACTERISTIC) { connection.read(service, "0000ffff-0000-1000-8000-00805f9b34fb") {} }
        assertCode(ErrorCode.UNKNOWN_CHARACTERISTIC) { connection.read("0000ffff-0000-1000-8000-00805f9b34fb", readable) {} }
        assertCode(ErrorCode.NOT_PERMITTED) { connection.read(service, writable) {} }
        assertCode(ErrorCode.NOT_PERMITTED) { connection.write(service, readable, byteArrayOf(1), withResponse = true) {} }
        assertCode(ErrorCode.NOT_PERMITTED) { connection.write(service, readable, byteArrayOf(1), withResponse = false) {} }
        assertCode(ErrorCode.NOT_PERMITTED) { connection.subscribe(service, readable, enable = true) {} }
    }

    @Test
    fun `writes without response fit maxWriteLength, with response go long`() {
        ready(agreedMtu = 23)
        assertCode(ErrorCode.INVALID_PARAMS) { connection.write(service, writable, ByteArray(21), withResponse = false) {} }
        connection.write(service, writable, ByteArray(20), withResponse = false, answers::add)
        assertEquals("write $service/$writable 20 false", link.calls.last())
        connection.onWrite(service, writable, 0)
        connection.write(service, writable, ByteArray(512), withResponse = true, answers::add)
        assertEquals("write $service/$writable 512 true", link.calls.last())
        connection.onWrite(service, writable, 0)
        assertEquals(2, answers.count { it.isSuccess })
    }

    @Test
    fun `a write that can't start is gatt`() {
        ready()
        link.writeStarts = false
        connection.write(service, writable, byteArrayOf(1), withResponse = true, answers::add)
        assertEquals(ErrorCode.GATT, code(answers.single()))
    }

    @Test
    fun `requests on a device run one at a time`() {
        ready()
        connection.read(service, readable, answers::add)
        connection.write(service, writable, byteArrayOf(1), withResponse = true, answers::add)
        assertEquals("the write waits for the read", "read $service/$readable", link.calls.last())
        connection.onRead(service, readable, byteArrayOf(9), 0)
        assertEquals("write $service/$writable 1 true", link.calls.last())
        connection.onWrite(service, writable, 0)
        assertTrue(answers.all { it.isSuccess })
    }

    @Test
    fun `a request without an answer in 10 s ends the connection`() {
        // The device may still answer, out of step (as on iOS).
        ready()
        connection.read(service, readable, answers::add)
        connection.write(service, writable, byteArrayOf(1), withResponse = true, answers::add)
        scheduler.advanceBy(10_000)
        assertEquals(listOf(ErrorCode.TIMEOUT, ErrorCode.NOT_CONNECTED), answers.map(::code))
        assertEquals("the write never started", "read $service/$readable", link.calls.last())
        val (event, params) = events.single()
        assertEquals("ble.disconnected", event)
        assertEquals("timeout", params.getString("reason"))
        assertTrue(link.closed)
        assertFalse(connection.isReady)
        assertEquals(1, closed)
    }

    @Test
    fun `subscribe writes the CCCD, notifications first`() {
        ready()
        connection.subscribe(service, notifying, enable = true, answers::add)
        assertEquals("cccd $service/$notifying true 0100", link.calls.last())
        assertTrue("answers once the device confirmed", answers.isEmpty())
        connection.onDescriptorWrite(service, notifying, 0)
        assertTrue(answers.single().isSuccess)

        connection.subscribe(service, indicating, enable = true, answers::add)
        assertEquals("indications when that is all there is", "cccd $service/$indicating true 0200", link.calls.last())
        connection.onDescriptorWrite(service, indicating, 0)

        connection.subscribe(service, notifying, enable = false, answers::add)
        assertEquals("cccd $service/$notifying false 0000", link.calls.last())
        connection.onDescriptorWrite(service, notifying, 13)
        assertEquals(ErrorCode.GATT, code(answers.last()))
    }

    @Test
    fun `a characteristic without a CCCD subscribes at once`() {
        ready()
        connection.subscribe(service, noCccd, enable = true, answers::add)
        assertTrue(answers.single().isSuccess)
    }

    @Test
    fun `notifications while connected`() {
        connection.onChanged(service, notifying, byteArrayOf(1))
        assertTrue(events.isEmpty())
        ready()
        connection.onChanged(service, notifying, byteArrayOf(7, 8))
        val (event, params) = events.single()
        assertEquals("ble.notification", event)
        assertEquals("AA:BB:CC:DD:EE:01", params.getString("deviceId"))
        assertEquals(service, params.getString("service"))
        assertEquals(notifying, params.getString("characteristic"))
        assertArrayEquals(byteArrayOf(7, 8), Base64.getDecoder().decode(params.getString("value")))
    }

    // Disconnects

    @Test
    fun `a remote disconnect fails what waits and ends with ble disconnected`() {
        ready()
        connection.read(service, readable, answers::add)
        connection.write(service, writable, byteArrayOf(1), withResponse = true, answers::add)
        connection.onConnectionStateChange(19, connected = false)
        assertEquals(listOf(ErrorCode.NOT_CONNECTED, ErrorCode.NOT_CONNECTED), answers.map(::code))
        val (event, params) = events.single()
        assertEquals("ble.disconnected", event)
        assertEquals("remote", params.getString("reason"))
        assertTrue(link.closed)
        assertEquals(1, closed)
        assertFalse(connection.isReady)
        connection.onChanged(service, notifying, byteArrayOf(1))
        connection.onConnectionStateChange(0, connected = false)
        assertEquals("ble.disconnected is the last event", 1, events.size)
        assertCode(ErrorCode.NOT_CONNECTED) { connection.read(service, readable) {} }
    }

    @Test
    fun `disconnect reasons`() {
        assertEquals("remote", BleConnection.disconnectReason(0))
        assertEquals("remote", BleConnection.disconnectReason(0x13))
        assertEquals("timeout", BleConnection.disconnectReason(0x08))
        assertEquals("error", BleConnection.disconnectReason(133))
        assertEquals("error", BleConnection.disconnectReason(0x3e))
        ready()
        connection.onConnectionStateChange(8, connected = false)
        assertEquals("timeout", events.single().second.getString("reason"))
        assertTrue(events.single().second.getString("message").contains("8"))
    }

    @Test
    fun `ble disconnect ends with requested`() {
        ready()
        connection.disconnect()
        val params = events.single().second
        assertEquals("requested", params.getString("reason"))
        assertFalse(params.has("message"))
        assertTrue(link.closed)
        connection.disconnect()
        assertEquals(1, events.size)
    }

    @Test
    fun `the page going away closes without events`() {
        ready()
        connection.read(service, readable, answers::add)
        connection.abandon()
        assertTrue(link.closed)
        assertTrue(events.isEmpty())
        assertEquals(ErrorCode.NOT_CONNECTED, code(answers.single()))
        assertEquals(1, closed)
        connection.onConnectionStateChange(0, connected = false)
        assertTrue(events.isEmpty())
    }

    @Test
    fun `property names`() {
        assertEquals(listOf("read", "write", "writeWithoutResponse", "notify", "indicate"), BleConnection.propertyNames(0x02 or 0x04 or 0x08 or 0x10 or 0x20 or 0x01 or 0x40 or 0x80))
        assertEquals(emptyList<String>(), BleConnection.propertyNames(0))
    }
}

/** A [GattLink] that records calls and lets the test answer them through the connection. */
private class FakeGattLink(private val services: List<GattService>, private val noCccd: Set<String> = emptySet()) : GattLink {
    val calls = mutableListOf<String>()
    var closed = false
    var discoverStarts = true
    var mtuStarts = true
    var writeStarts = true

    override fun discoverServices(): Boolean {
        calls += "discoverServices"
        return discoverStarts
    }

    override fun requestMtu(mtu: Int): Boolean {
        calls += "requestMtu $mtu"
        return mtuStarts
    }

    override fun services(): List<GattService> = services

    override fun read(service: String, characteristic: String): Boolean {
        calls += "read $service/$characteristic"
        return true
    }

    override fun write(service: String, characteristic: String, value: ByteArray, withResponse: Boolean): Boolean {
        calls += "write $service/$characteristic ${value.size} $withResponse"
        return writeStarts
    }

    override fun setNotifications(service: String, characteristic: String, enable: Boolean, cccd: ByteArray): GattLink.CccdWrite {
        if (characteristic in noCccd) return GattLink.CccdWrite.NO_DESCRIPTOR
        calls += "cccd $service/$characteristic $enable ${cccd.joinToString("") { "%02x".format(it) }}"
        return GattLink.CccdWrite.STARTED
    }

    override fun close() {
        closed = true
    }
}
