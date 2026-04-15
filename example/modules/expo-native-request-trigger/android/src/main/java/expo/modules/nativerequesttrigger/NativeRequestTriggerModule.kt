package expo.modules.nativerequesttrigger

import android.util.Log
import expo.modules.inappdebugger.InAppDebuggerOkHttpIntegration
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import java.io.IOException
import java.util.Locale
import java.util.concurrent.TimeUnit
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response

private const val TAG = "NativeRequestTrigger"

private val nativeRequestClient: OkHttpClient by lazy {
  val builder =
    OkHttpClient.Builder()
      .connectTimeout(15, TimeUnit.SECONDS)
      .readTimeout(20, TimeUnit.SECONDS)
      .writeTimeout(20, TimeUnit.SECONDS)

  // This mirrors how a host-owned native module should wire its own OkHttp stack.
  InAppDebuggerOkHttpIntegration.instrument(builder)
  builder.build()
}

class NativeRequestTriggerModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("NativeRequestTrigger")

    AsyncFunction("sendHttpRequest") { rawOptions: Map<String, Any?> ->
      val url =
        (rawOptions["url"] as? String)
          ?.trim()
          ?.takeIf { it.isNotEmpty() }
          ?: throw IllegalArgumentException("NativeRequestTrigger.sendHttpRequest requires a non-empty url.")
      val method = ((rawOptions["method"] as? String) ?: "GET").uppercase(Locale.US)
      val body = rawOptions["body"]?.toString()
      val headers = normalizeHeaders(rawOptions["headers"] as? Map<*, *>)
      val request = buildRequest(url = url, method = method, body = body, headers = headers)

      nativeRequestClient.newCall(request).enqueue(
        object : Callback {
          override fun onFailure(call: Call, e: IOException) {
            Log.w(TAG, "Native $method failed for $url: ${e.message}", e)
          }

          override fun onResponse(call: Call, response: Response) {
            response.use {
              // Drain the body so the debugger can observe the full native request lifecycle.
              it.body?.bytes()
              Log.i(TAG, "Native $method completed for $url with status ${it.code}")
            }
          }
        }
      )
    }
  }
}

private fun normalizeHeaders(rawHeaders: Map<*, *>?): Map<String, String> {
  val headers =
    linkedMapOf(
      "Accept" to "application/json",
      "X-Debug-Native-Plugin" to "example-expo-module",
      "X-Debug-Native-Platform" to "android"
    )

  rawHeaders?.forEach { (key, value) ->
    val normalizedKey = key as? String ?: return@forEach
    headers[normalizedKey] = value?.toString() ?: ""
  }
  return headers
}

private fun buildRequest(
  url: String,
  method: String,
  body: String?,
  headers: Map<String, String>
): Request {
  val requestBuilder = Request.Builder().url(url)
  headers.forEach { (key, value) ->
    requestBuilder.header(key, value)
  }

  return when (method) {
    "GET" -> requestBuilder.get().build()
    "POST" -> {
      val contentType =
        headers.entries.firstOrNull { it.key.equals("Content-Type", ignoreCase = true) }?.value
          ?: "application/json; charset=utf-8"
      requestBuilder
        .post((body ?: "").toRequestBody(contentType.toMediaTypeOrNull()))
        .build()
    }
    else -> throw IllegalArgumentException("NativeRequestTrigger only supports GET and POST, received $method.")
  }
}
