package com.plugchoice.internal

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.InputStream
import java.net.ProtocolException
import java.util.Base64
import java.util.Locale

/**
 * HTTP/1.1 framing for `http.session` (PROTOCOL.md §9.5): requests go out on one kept-alive TLS
 * connection, so the shell writes and reads the messages itself instead of handing them to
 * OkHttp (which pools connections and silently opens new ones).
 */
internal object Http1 {
    /**
     * Headers the shell writes itself; the page's values for them are dropped. A page-supplied
     * `Connection: close` would end the session, and a second `Content-Length` would corrupt the
     * framing.
     */
    val SHELL_OWNED_HEADERS = setOf("host", "content-length", "transfer-encoding", "connection")

    const val MAX_HEADER_BYTES = 64 * 1024
    const val MAX_BODY_BYTES = 16 * 1024 * 1024

    class Response(
        val status: Int,
        /** Lower-cased names; repeated headers joined with ", ". */
        val headers: Map<String, String>,
        val body: ByteArray,
        /** The device closes the connection after this response. */
        val closesConnection: Boolean,
    ) {
        fun toJson(responseBody: ResponseBody = ResponseBody.TEXT): JSONObject {
            val headerObject = JSONObject()
            for ((name, value) in headers) headerObject.put(name, value)
            return JSONObject()
                .put("status", status)
                .put("headers", headerObject)
                .put("body", responseBody.encode(body))
        }
    }

    /** How a response body reaches the page (PROTOCOL §9.2): as UTF-8 text, or as base64 of its bytes, for a binary body such as an archive. */
    enum class ResponseBody(val param: String) {
        TEXT("text"),
        BASE64("base64");

        fun encode(body: ByteArray): String = when (this) {
            TEXT -> String(body, Charsets.UTF_8)
            BASE64 -> Base64.getEncoder().encodeToString(body)
        }

        companion object {
            /** `responseBody` (absent: `text`). */
            fun parse(params: JSONObject): ResponseBody {
                if (!params.has("responseBody") || params.isNull("responseBody")) return TEXT
                val value = params.opt("responseBody")
                return entries.firstOrNull { it.param == value }
                    ?: throw BridgeException.invalidParams("responseBody must be text or base64")
            }
        }
    }

    // Requests

    /**
     * `GET`/`POST`/`PUT` with an origin-form [path]. POST and PUT always carry an explicit
     * `Content-Length` (0 without a body); the device rejects chunked bodies, so there never is one.
     */
    fun encodeRequest(method: String, path: String, host: String, port: Int, headers: Map<String, String>, body: String?): ByteArray {
        val head = StringBuilder()
        head.append(method).append(' ').append(path).append(" HTTP/1.1\r\n")
        head.append("Host: ").append(hostHeader(host, port)).append("\r\n")
        for ((name, value) in headers.toSortedMap()) {
            if (name.lowercase(Locale.ROOT) in SHELL_OWNED_HEADERS) continue
            head.append(name).append(": ").append(value).append("\r\n")
        }
        val payload = if (method == "GET") ByteArray(0) else (body ?: "").toByteArray(Charsets.UTF_8)
        if (method != "GET") head.append("Content-Length: ").append(payload.size).append("\r\n")
        head.append("\r\n")
        return head.toString().toByteArray(Charsets.UTF_8) + payload
    }

    fun hostHeader(host: String, port: Int): String {
        val name = if (':' in host) "[$host]" else host
        return if (port == 443) name else "$name:$port"
    }

    /** An origin-form request target: starts with `/`, printable ASCII, no spaces and no fragment. */
    fun isValidPath(path: String): Boolean =
        path.startsWith("/") && path.all { it.code in 0x21..0x7E && it != '#' }

    /** A header name is an RFC 9110 token. */
    fun isValidHeaderName(name: String): Boolean =
        name.isNotEmpty() && name.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it in "!#$%&'*+-.^_`|~" }

    /**
     * Visible ASCII, spaces and tabs: no control characters (CR and LF would split the header
     * section) and nothing a client library would encode its own way.
     */
    fun isValidHeaderValue(value: String): Boolean = value.all { it == '\t' || it in ' '..'~' }

    // Responses

    /**
     * Reads one response (blocking). Bodies framed by `Content-Length`, chunked, or by the end of
     * the connection; 1xx interim responses are skipped. Throws [ProtocolException] for a
     * malformed response and [EOFException] when the device closes the connection early.
     */
    fun readResponse(input: InputStream): Response {
        while (true) {
            val statusLine = readLine(input, allowEof = true)
                ?: throw EOFException("the device closed the connection")
            val parts = statusLine.split(' ', limit = 3)
            val code = parts.getOrNull(1)?.takeIf { it.length == 3 }?.toIntOrNull()
            if (!parts[0].startsWith("HTTP/1.") || code == null || code < 100) {
                throw ProtocolException("not an HTTP/1.x response")
            }
            val headers = LinkedHashMap<String, String>()
            var headerBytes = statusLine.length
            while (true) {
                val line = readLine(input) ?: throw EOFException("the device closed the connection")
                if (line.isEmpty()) break
                headerBytes += line.length + 2
                if (headerBytes > MAX_HEADER_BYTES) throw ProtocolException("response header section is too large")
                val colon = line.indexOf(':')
                if (colon <= 0) throw ProtocolException("bad header line")
                val name = line.substring(0, colon).trim().lowercase(Locale.ROOT)
                val value = line.substring(colon + 1).trim()
                headers[name] = headers[name]?.let { "$it, $value" } ?: value
            }
            // Interim responses (100 Continue and the like): the real one follows.
            if (code in 100..199 && code != 101) continue

            val connection = headers["connection"].orEmpty().lowercase(Locale.ROOT).split(',').map { it.trim() }
            var closes = "close" in connection || (parts[0] == "HTTP/1.0" && "keep-alive" !in connection)
            val body = when {
                code == 204 || code == 304 || code in 100..199 -> ByteArray(0)
                headers["transfer-encoding"]?.lowercase(Locale.ROOT)?.contains("chunked") == true -> readChunked(input)
                headers["content-length"] != null -> {
                    val values = headers.getValue("content-length").split(',').map { it.trim() }.toSet()
                    val length = values.singleOrNull()?.toLongOrNull()
                    if (length == null || length < 0) throw ProtocolException("bad Content-Length")
                    if (length > MAX_BODY_BYTES) throw ProtocolException("response body is too large")
                    readExactly(input, length.toInt())
                }
                else -> {
                    // No length: the body runs until the device closes the connection.
                    closes = true
                    readUntilEof(input)
                }
            }
            return Response(code, headers, body, closes)
        }
    }

    private fun readChunked(input: InputStream): ByteArray {
        val body = ByteArrayOutputStream()
        while (true) {
            val line = readLine(input) ?: throw EOFException("the device closed the connection")
            val size = line.substringBefore(';').trim().toIntOrNull(16)
            if (size == null || size < 0) throw ProtocolException("bad chunk size")
            if (size == 0) break
            if (body.size() + size > MAX_BODY_BYTES) throw ProtocolException("response body is too large")
            body.write(readExactly(input, size))
            if (readLine(input) != "") throw ProtocolException("bad chunk framing")
        }
        // Trailers, up to the empty line.
        while (true) {
            val line = readLine(input) ?: throw EOFException("the device closed the connection")
            if (line.isEmpty()) break
        }
        return body.toByteArray()
    }

    private fun readExactly(input: InputStream, count: Int): ByteArray {
        val bytes = ByteArray(count)
        var read = 0
        while (read < count) {
            val n = input.read(bytes, read, count - read)
            if (n < 0) throw EOFException("the device closed the connection before the response was complete")
            read += n
        }
        return bytes
    }

    private fun readUntilEof(input: InputStream): ByteArray {
        val body = ByteArrayOutputStream()
        val buffer = ByteArray(8 * 1024)
        while (true) {
            val n = input.read(buffer)
            if (n < 0) break
            body.write(buffer, 0, n)
            if (body.size() > MAX_BODY_BYTES) throw ProtocolException("response body is too large")
        }
        return body.toByteArray()
    }

    /** A CRLF-terminated line without its CRLF; null at the end of the stream when [allowEof]. */
    private fun readLine(input: InputStream, allowEof: Boolean = false): String? {
        val line = ByteArrayOutputStream()
        while (true) {
            val byte = input.read()
            if (byte < 0) {
                if (allowEof && line.size() == 0) return null
                throw EOFException("the device closed the connection before the response was complete")
            }
            if (byte == '\n'.code) {
                val bytes = line.toByteArray()
                val end = if (bytes.isNotEmpty() && bytes.last() == '\r'.code.toByte()) bytes.size - 1 else bytes.size
                return String(bytes, 0, end, Charsets.UTF_8)
            }
            line.write(byte)
            if (line.size() > MAX_HEADER_BYTES) throw ProtocolException("response line is too long")
        }
    }
}
