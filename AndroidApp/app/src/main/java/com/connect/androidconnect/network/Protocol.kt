package com.connect.androidconnect.network

import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream

object Protocol {
    const val PORT = 58000
    const val EVENT_PORT = 58001        // Android → Mac push channel
    const val SERVICE_TYPE = "_androidconnect._tcp."
    const val SERVICE_NAME = "AndroidConnect"
    const val BUFFER_SIZE = 65536 // 64 KB chunks → saturates WiFi easily

    fun readMessage(dis: DataInputStream): JSONObject {
        val len = dis.readInt()
        require(len in 1..10_485_760) { "Bad message length: $len" }
        val data = ByteArray(len)
        dis.readFully(data)
        return JSONObject(String(data, Charsets.UTF_8))
    }

    fun writeMessage(dos: DataOutputStream, json: JSONObject) {
        val data = json.toString().toByteArray(Charsets.UTF_8)
        dos.writeInt(data.size)
        dos.write(data)
        dos.flush()
    }
}
