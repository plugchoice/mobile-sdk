package com.plugchoice.internal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream

/** The HTTP/1.1 framing under `http.session`. */
class Http1Test {

    private fun input(text: String): InputStream = ByteArrayInputStream(text.toByteArray())

    private fun read(text: String): Http1.Response = Http1.readResponse(input(text))

    private fun assertMalformed(text: String) {
        try {
            read(text)
            fail("parsed $text")
        } catch (_: IOException) {
        }
    }

    @Test
    fun `a binary body as base64, and as text by default`() {
        // A gzip header: not UTF-8, so text would lose it.
        val gzip = byteArrayOf(0x1F, 0x8B.toByte(), 0x08, 0x00, 0xFF.toByte())
        val response = Http1.readResponse(ByteArrayInputStream("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n".toByteArray() + gzip))
        assertEquals("H4sIAP8=", response.toJson(Http1.ResponseBody.BASE64).getString("body"))
        assertTrue(java.util.Base64.getDecoder().decode(response.toJson(Http1.ResponseBody.BASE64).getString("body")).contentEquals(gzip))
        assertEquals("ok", read("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok").toJson().getString("body"))
    }

    @Test
    fun `a Content-Length body`() {
        val response = read("HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nhello world")
        assertEquals(200, response.status)
        assertEquals("hello world", String(response.body))
        assertFalse(response.closesConnection)
    }

    @Test
    fun `a chunked body with extensions and trailers`() {
        val response = read("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;name=value\r\nhello\r\n6\r\n world\r\n0\r\nX-Trailer: 1\r\n\r\n")
        assertEquals("hello world", String(response.body))
    }

    @Test
    fun `a body until the connection closes`() {
        val response = read("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nall of it")
        assertEquals("all of it", String(response.body))
        assertTrue(response.closesConnection)
    }

    @Test
    fun `responses without a body`() {
        assertEquals(0, read("HTTP/1.1 204 No Content\r\n\r\n").body.size)
        assertEquals(304, read("HTTP/1.1 304 Not Modified\r\nContent-Length: 10\r\n\r\n").status)
        assertEquals(401, read("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n").status)
    }

    @Test
    fun `interim responses are skipped`() {
        assertEquals(201, read("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 201 Created\r\nContent-Length: 2\r\n\r\nok").status)
    }

    @Test
    fun `headers are lower-cased and repeats joined`() {
        val response = read("HTTP/1.1 200 OK\r\nSet-Cookie: a=1\r\nset-cookie: b=2\r\nX-Thing:  spaced \r\nContent-Length: 0\r\n\r\n")
        assertEquals("a=1, b=2", response.headers["set-cookie"])
        assertEquals("spaced", response.headers["x-thing"])
        val json = response.toJson()
        assertEquals(200, json.getInt("status"))
        assertEquals("a=1, b=2", json.getJSONObject("headers").getString("set-cookie"))
        assertEquals(setOf("set-cookie", "x-thing", "content-length"), json.getJSONObject("headers").keys().asSequence().toSet())
        assertEquals("", json.getString("body"))
    }

    @Test
    fun `connection close`() {
        assertTrue(read("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 0\r\n\r\n").closesConnection)
        assertTrue(read("HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n").closesConnection)
        assertFalse(read("HTTP/1.0 200 OK\r\nConnection: keep-alive\r\nContent-Length: 0\r\n\r\n").closesConnection)
        assertFalse(read("HTTP/1.1 200 OK\r\nConnection: Keep-Alive\r\nContent-Length: 0\r\n\r\n").closesConnection)
    }

    @Test
    fun `responses read one after the other from one stream`() {
        val stream = input("HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\naHTTP/1.1 202 Accepted\r\nContent-Length: 1\r\n\r\nb")
        assertEquals(200, Http1.readResponse(stream).status)
        val second = Http1.readResponse(stream)
        assertEquals(202, second.status)
        assertEquals("b", String(second.body))
    }

    @Test
    fun `malformed or cut-off responses fail`() {
        assertMalformed("SSH-2.0-OpenSSH_9.0\r\n\r\n")
        assertMalformed("HTTP/1.1 2000 OK\r\n\r\n")
        assertMalformed("HTTP/1.1 200 OK\r\nno colon here\r\n\r\n")
        assertMalformed("HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n")
        assertMalformed("HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n")
        assertMalformed("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n")
        assertMalformed("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort")
        assertMalformed("HTTP/1.1 200 OK\r\nContent-Le")
        assertMalformed("")
    }

    @Test
    fun `request encoding`() {
        assertEquals(
            "GET /api/info HTTP/1.1\r\nHost: 10.206.2.88\r\nAccept: application/json\r\n\r\n",
            String(Http1.encodeRequest("GET", "/api/info", "10.206.2.88", 443, mapOf("Accept" to "application/json"), null)),
        )
        assertEquals(
            "PUT /x HTTP/1.1\r\nHost: [::1]:8443\r\nContent-Length: 6\r\n\r\nhéllo",
            String(Http1.encodeRequest("PUT", "/x", "::1", 8443, mapOf("transfer-encoding" to "chunked"), "héllo")),
        )
        // An empty POST still says how long it is.
        assertEquals(
            "POST /api/logout HTTP/1.1\r\nHost: 10.0.0.2\r\nContent-Length: 0\r\n\r\n",
            String(Http1.encodeRequest("POST", "/api/logout", "10.0.0.2", 443, mapOf("Connection" to "close", "Host" to "evil"), null)),
        )
    }

    @Test
    fun `request validation`() {
        assertTrue(Http1.isValidPath("/"))
        assertTrue(Http1.isValidPath("/api/prop?ids=2053_0,20F0_3&offset=32"))
        assertFalse(Http1.isValidPath(""))
        assertFalse(Http1.isValidPath("api"))
        assertFalse(Http1.isValidPath("/a\r\nHost: x"))
        assertTrue(Http1.isValidHeaderName("Content-Type"))
        assertFalse(Http1.isValidHeaderName("Content Type"))
        assertFalse(Http1.isValidHeaderName(""))
        assertFalse(Http1.isValidHeaderName("X:Y"))
        assertTrue(Http1.isValidHeaderValue("application/json; charset=utf-8"))
        assertFalse(Http1.isValidHeaderValue("a\nb"))
    }
}
