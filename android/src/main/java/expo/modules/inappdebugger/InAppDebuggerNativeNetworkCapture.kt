package expo.modules.inappdebugger

import android.content.Context
import com.facebook.react.modules.network.CustomClientBuilder
import com.facebook.react.modules.network.NetworkingModule
import com.facebook.react.modules.network.OkHttpClientFactory
import com.facebook.react.modules.network.OkHttpClientProvider
import com.facebook.react.modules.websocket.WebSocketModule
import java.io.IOException
import java.lang.ref.WeakReference
import java.net.InetSocketAddress
import java.net.Proxy
import java.util.Locale
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.max
import okhttp3.Call
import okhttp3.Connection
import okhttp3.EventListener
import okhttp3.Handshake
import okhttp3.Headers
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.Response
import okio.Buffer

private const val NATIVE_HTTP_ID_PREFIX = "native_http_"
private const val NATIVE_WS_ID_PREFIX = "native_ws_"
private const val MAX_BODY_PREVIEW_BYTES = 32_000L
private const val MAX_BINARY_PREVIEW_BYTES = 48
private const val MAX_EVENT_REDIRECTS = 8
private const val MAX_EVENT_LINES = 48

object InAppDebuggerNativeNetworkCapture {
  private val lock = Any()
  private val requestCounter = AtomicLong(0)
  private val interceptor = NativeOkHttpCaptureInterceptor()

  private var appContextRef: WeakReference<Context>? = null
  private var enabled = false
  private var hooksInstalled = false
  private val activeCalls = mutableMapOf<Call, NativeOkHttpCallState>()

  fun applyConfig(context: Context?, config: DebugConfig) {
    synchronized(lock) {
      if (context != null) {
        appContextRef = WeakReference(context.applicationContext)
      }
      enabled = config.enabled && config.enableNetworkTab
      if (enabled) {
        installHooksLocked()
      }
    }
  }

  fun shutdown() {
    synchronized(lock) {
      enabled = false
      activeCalls.clear()
    }
  }

  fun applyTo(builder: OkHttpClient.Builder): OkHttpClient.Builder {
    val currentInterceptors = builder.interceptors()
    if (currentInterceptors.none { it === interceptor || it is NativeOkHttpCaptureInterceptor }) {
      builder.addInterceptor(interceptor)
    }
    val existingFactory = resolveBuilderEventListenerFactory(builder)
    builder.eventListenerFactory(compositeEventListenerFactory(existingFactory))
    return builder
  }

  internal fun shouldCapture(request: Request): Boolean {
    synchronized(lock) {
      if (!enabled) {
        return false
      }
    }

    val scheme = request.url.scheme.lowercase(Locale.ROOT)
    if (scheme != "http" && scheme != "https" && scheme != "ws" && scheme != "wss") {
      return false
    }

    // RN NetworkingModule / WebSocketModule tag requests with numeric ids.
    if (request.tag() is Number) {
      return false
    }

    return true
  }

  internal fun ensureCallState(call: Call, request: Request): NativeOkHttpCallState {
    synchronized(lock) {
      return activeCalls.getOrPut(call) { createCallStateLocked(request) }
    }
  }

  internal fun emitPending(call: Call, request: Request, requestBody: String?) {
    val entry = synchronized(lock) {
      val state = activeCalls.getOrPut(call) { createCallStateLocked(request) }
      if (requestBody != null && state.requestBody == null) {
        state.requestBody = requestBody
        state.dirty = true
      }
      if (state.startEmitted) {
        return@synchronized null
      }
      state.startEmitted = true
      state.toEntryLocked()
    }
    entry?.let(InAppDebuggerStore::upsertNetworkEntry)
  }

  internal fun emitResponse(call: Call, request: Request, response: Response) {
    val entry = synchronized(lock) {
      val state = activeCalls.getOrPut(call) { createCallStateLocked(request) }
      val timestamp = System.currentTimeMillis()

      appendRedirectEventsLocked(state, response, timestamp)
      state.updatedAt = timestamp
      state.status = response.code
      state.responseHeaders = response.headers.toDebugHeaderMap()
      state.responseContentType = response.header("Content-Type") ?: response.body?.contentType()?.toString()
      state.url = response.request.url.toString()

      if (state.kind == "websocket") {
        state.protocol = response.header("Sec-WebSocket-Protocol") ?: state.protocol
        state.state = if (response.code == 101) "open" else "error"
        state.durationMs = max(0L, timestamp - state.startedAt)
        if (response.code != 101) {
          state.endedAt = timestamp
          state.error = "WebSocket handshake failed with HTTP ${response.code}"
        }
      } else {
        val preview = response.previewResponseBody()
        state.protocol = normalizeProtocol(response.protocol)
        state.responseBody = preview.preview
        state.responseType = normalizedResponseType(state.responseContentType)
        state.responseSize =
          preview.size
            ?: state.responseBodyBytesObserved?.coerceAtMost(Int.MAX_VALUE.toLong())?.toInt()
        state.state = if (response.code >= 400) "error" else "success"
        state.endedAt = timestamp
        state.durationMs = max(0L, timestamp - state.startedAt)
      }

      state.toEntryLocked()
    }
    entry?.let(InAppDebuggerStore::upsertNetworkEntry)
  }

  internal fun emitFailure(call: Call, request: Request, throwable: Throwable) {
    val entry = synchronized(lock) {
      val state = activeCalls.getOrPut(call) { createCallStateLocked(request) }
      val timestamp = System.currentTimeMillis()
      state.updatedAt = timestamp
      state.endedAt = timestamp
      state.durationMs = max(0L, timestamp - state.startedAt)
      state.state = "error"
      state.error = throwable.message ?: throwable.javaClass.simpleName
      appendEventLocked(
        state,
        timestamp,
        "failure ${throwable.javaClass.simpleName}: ${throwable.message ?: "Request failed"}"
      )
      state.toEntryLocked()
    }
    entry?.let(InAppDebuggerStore::upsertNetworkEntry)
  }

  internal fun appendEvent(
    call: Call,
    timestamp: Long = System.currentTimeMillis(),
    eventText: String,
    mutate: (NativeOkHttpCallState.() -> Unit)? = null
  ) {
    synchronized(lock) {
      val state = activeCalls[call] ?: return
      state.updatedAt = max(state.updatedAt, timestamp)
      mutate?.invoke(state)
      appendEventLocked(state, timestamp, eventText)
    }
  }

  internal fun finalizeFromListener(
    call: Call,
    timestamp: Long = System.currentTimeMillis(),
    mutate: NativeOkHttpCallState.() -> Unit = {}
  ) {
    val entry = synchronized(lock) {
      val state = activeCalls.remove(call) ?: return
      state.updatedAt = max(state.updatedAt, timestamp)
      mutate(state)
      if (!state.startEmitted || !state.dirty) {
        return
      }
      state.toEntryLocked()
    }
    entry?.let(InAppDebuggerStore::upsertNetworkEntry)
  }

  internal fun appendStatus(type: String, message: String, details: String? = null) {
    InAppDebuggerStore.appendNativeLog(
      createNativeDebugLogEntry(
        type = type,
        message = message,
        context = "android-native-network",
        details = details
      )
    )
  }

  private fun installHooksLocked() {
    runCatching {
      installOkHttpClientProviderHookLocked()
      installReactNetworkingHookLocked()
      installReactWebSocketHookLocked()
      hooksInstalled = true
    }.onFailure { error ->
      appendStatus(
        type = "warn",
        message = "Android native network capture could not install all OkHttp hooks.",
        details = error.stackTraceToString()
      )
    }
  }

  private fun installOkHttpClientProviderHookLocked() {
    val providerClass = OkHttpClientProvider::class.java
    val currentFactory = providerClass.readObjectField<OkHttpClientFactory>("factory", OkHttpClientProvider)
    if (currentFactory !is InstrumentedOkHttpClientFactory) {
      providerClass.writeObjectField(
        name = "factory",
        receiver = OkHttpClientProvider,
        value = InstrumentedOkHttpClientFactory(currentFactory)
      )
    }

    val currentClient = providerClass.readObjectField<OkHttpClient>("client", OkHttpClientProvider)
    if (currentClient != null) {
      providerClass.writeObjectField(
        name = "client",
        receiver = OkHttpClientProvider,
        value = instrument(currentClient)
      )
    }
  }

  private fun installReactNetworkingHookLocked() {
    val currentBuilder = NetworkingModule::class.java.readStaticField<CustomClientBuilder>("customClientBuilder")
    if (currentBuilder !is InstrumentedReactClientBuilder) {
      NetworkingModule.setCustomClientBuilder(InstrumentedReactClientBuilder(currentBuilder))
    }
  }

  private fun installReactWebSocketHookLocked() {
    val currentBuilder = WebSocketModule::class.java.readStaticField<CustomClientBuilder>("customClientBuilder")
    if (currentBuilder !is InstrumentedReactClientBuilder) {
      WebSocketModule.setCustomClientBuilder(InstrumentedReactClientBuilder(currentBuilder))
    }
  }

  private fun createBaseClient(): OkHttpClient {
    val context = appContextRef?.get()
    val builder =
      if (context != null) {
        OkHttpClientProvider.createClientBuilder(context)
      } else {
        OkHttpClientProvider.createClientBuilder()
      }
    return applyTo(builder).build()
  }

  private fun instrument(client: OkHttpClient): OkHttpClient {
    if (
      client.interceptors.any { it === interceptor || it is NativeOkHttpCaptureInterceptor } &&
        client.eventListenerFactory is InstrumentedEventListenerFactory
    ) {
      return client
    }
    val builder = client.newBuilder()
    if (builder.interceptors().none { it === interceptor || it is NativeOkHttpCaptureInterceptor }) {
      builder.addInterceptor(interceptor)
    }
    builder.eventListenerFactory(compositeEventListenerFactory(client.eventListenerFactory))
    return builder.build()
  }

  private fun compositeEventListenerFactory(
    existingFactory: EventListener.Factory?
  ): EventListener.Factory {
    if (existingFactory is InstrumentedEventListenerFactory) {
      return existingFactory
    }
    return InstrumentedEventListenerFactory(existingFactory)
  }

  private fun resolveBuilderEventListenerFactory(builder: OkHttpClient.Builder): EventListener.Factory? {
    return runCatching {
      val method = builder.javaClass.getMethod("getEventListenerFactory\$okhttp")
      method.invoke(builder) as? EventListener.Factory
    }.getOrNull()
  }

  private fun createCallStateLocked(request: Request): NativeOkHttpCallState {
    val startedAt = System.currentTimeMillis()
    val isWebSocket = isWebSocketUpgrade(request)
    val method =
      if (isWebSocket) {
        webSocketMethod(request.url.toString())
      } else {
        request.method.uppercase(Locale.ROOT)
      }
    val state = NativeOkHttpCallState(
      requestId = buildRequestId(isWebSocket, startedAt),
      kind = if (isWebSocket) "websocket" else "http",
      method = method,
      url = request.url.toString(),
      startedAt = startedAt,
      updatedAt = startedAt,
      requestHeaders = request.headers.toDebugHeaderMap(),
      requestedProtocols = request.header("Sec-WebSocket-Protocol")?.takeIf { it.isNotBlank() },
      state = if (isWebSocket) "connecting" else "pending"
    )
    appendEventLocked(state, startedAt, "start ${state.method} ${state.url}")
    return state
  }

  private fun buildRequestId(isWebSocket: Boolean, startedAt: Long): String {
    val prefix = if (isWebSocket) NATIVE_WS_ID_PREFIX else NATIVE_HTTP_ID_PREFIX
    return prefix + startedAt + "_" + requestCounter.incrementAndGet()
  }

  private fun appendRedirectEventsLocked(
    state: NativeOkHttpCallState,
    response: Response,
    timestamp: Long
  ) {
    if (state.redirectsRecorded) {
      return
    }
    val redirects = buildRedirectChain(response)
    if (redirects.isEmpty()) {
      return
    }
    redirects.forEach { redirectedResponse ->
      val location =
        redirectedResponse.header("Location")?.takeIf { it.isNotBlank() }
          ?: redirectedResponse.request.url.toString()
      appendEventLocked(state, timestamp, "redirect ${redirectedResponse.code} -> $location")
    }
    state.redirectsRecorded = true
  }

  private fun appendEventLocked(
    state: NativeOkHttpCallState,
    timestamp: Long,
    eventText: String
  ) {
    if (state.events.size >= MAX_EVENT_LINES) {
      if (!state.truncatedEvents) {
        state.events += "[${formatNativeNetworkClock(timestamp)}] ...more events omitted..."
        state.truncatedEvents = true
        state.dirty = true
      }
      return
    }
    state.events += "[${formatNativeNetworkClock(timestamp)}] $eventText"
    state.dirty = true
  }

  private fun webSocketMethod(url: String): String {
    return when (runCatching { Request.Builder().url(url).build().url.scheme }.getOrNull()?.lowercase(Locale.ROOT)) {
      "wss", "https" -> "WSS"
      else -> "WS"
    }
  }

  private class InstrumentedOkHttpClientFactory(
    private val delegate: OkHttpClientFactory?
  ) : OkHttpClientFactory {
    override fun createNewNetworkModuleClient(): OkHttpClient {
      val baseClient = delegate?.createNewNetworkModuleClient() ?: createBaseClient()
      return instrument(baseClient)
    }
  }

  private class InstrumentedReactClientBuilder(
    private val delegate: CustomClientBuilder?
  ) : CustomClientBuilder {
    override fun apply(builder: OkHttpClient.Builder) {
      delegate?.apply(builder)
      applyTo(builder)
    }
  }
}

internal data class NativeOkHttpCallState(
  val requestId: String,
  val kind: String,
  var method: String,
  var url: String,
  val startedAt: Long,
  var updatedAt: Long,
  val requestHeaders: Map<String, String>,
  var responseHeaders: Map<String, String> = emptyMap(),
  var requestBody: String? = null,
  var responseBody: String? = null,
  var responseType: String? = null,
  var responseContentType: String? = null,
  var responseSize: Int? = null,
  var state: String,
  var status: Int? = null,
  var error: String? = null,
  var protocol: String? = null,
  var requestedProtocols: String? = null,
  var endedAt: Long? = null,
  var durationMs: Long? = null,
  var requestBodyBytesObserved: Long? = null,
  var responseBodyBytesObserved: Long? = null,
  val events: MutableList<String> = ArrayList(16),
  var startEmitted: Boolean = false,
  var dirty: Boolean = true,
  var redirectsRecorded: Boolean = false,
  var truncatedEvents: Boolean = false
) {
  fun toEntryLocked(): DebugNetworkEntry {
    dirty = false
    return DebugNetworkEntry(
      id = requestId,
      kind = kind,
      method = method,
      url = url,
      origin = "native",
      state = state,
      startedAt = startedAt,
      updatedAt = updatedAt,
      endedAt = endedAt,
      durationMs = durationMs,
      status = status,
      requestHeaders = requestHeaders,
      responseHeaders = responseHeaders,
      requestBody = requestBody,
      responseBody = responseBody,
      responseType = responseType,
      responseContentType = responseContentType,
      responseSize = responseSize,
      error = error,
      protocol = protocol,
      requestedProtocols = requestedProtocols,
      events = events.joinToString("\n")
    )
  }
}

private class NativeOkHttpCaptureInterceptor : Interceptor {
  override fun intercept(chain: Interceptor.Chain): Response {
    val request = chain.request()
    if (!InAppDebuggerNativeNetworkCapture.shouldCapture(request)) {
      return chain.proceed(request)
    }

    val call = chain.call()
    InAppDebuggerNativeNetworkCapture.ensureCallState(call, request)
    val requestBody =
      if (isWebSocketUpgrade(request)) {
        null
      } else {
        request.body.previewRequestBody(request.header("Content-Type"))
      }
    InAppDebuggerNativeNetworkCapture.emitPending(call, request, requestBody)

    return try {
      val response = chain.proceed(request)
      InAppDebuggerNativeNetworkCapture.emitResponse(call, request, response)
      response
    } catch (throwable: Throwable) {
      InAppDebuggerNativeNetworkCapture.emitFailure(call, request, throwable)
      throw throwable
    }
  }
}

private class InstrumentedEventListenerFactory(
  private val delegate: EventListener.Factory?
) : EventListener.Factory {
  override fun create(call: Call): EventListener {
    val delegateListener = delegate?.create(call) ?: EventListener.NONE
    val nativeListener =
      if (InAppDebuggerNativeNetworkCapture.shouldCapture(call.request())) {
        InAppDebuggerNativeNetworkCapture.ensureCallState(call, call.request())
        NativeOkHttpEventListener(call)
      } else {
        EventListener.NONE
      }

    return when {
      delegateListener === EventListener.NONE -> nativeListener
      nativeListener === EventListener.NONE -> delegateListener
      else -> CompositeEventListener(delegateListener, nativeListener)
    }
  }
}

private class CompositeEventListener(
  private val primary: EventListener,
  private val secondary: EventListener
) : EventListener() {
  override fun callStart(call: Call) {
    primary.callStart(call)
    secondary.callStart(call)
  }

  override fun proxySelectStart(call: Call, url: okhttp3.HttpUrl) {
    primary.proxySelectStart(call, url)
    secondary.proxySelectStart(call, url)
  }

  override fun proxySelectEnd(call: Call, url: okhttp3.HttpUrl, proxies: List<Proxy>) {
    primary.proxySelectEnd(call, url, proxies)
    secondary.proxySelectEnd(call, url, proxies)
  }

  override fun dnsStart(call: Call, domainName: String) {
    primary.dnsStart(call, domainName)
    secondary.dnsStart(call, domainName)
  }

  override fun dnsEnd(call: Call, domainName: String, inetAddressList: List<java.net.InetAddress>) {
    primary.dnsEnd(call, domainName, inetAddressList)
    secondary.dnsEnd(call, domainName, inetAddressList)
  }

  override fun connectStart(call: Call, inetSocketAddress: InetSocketAddress, proxy: Proxy) {
    primary.connectStart(call, inetSocketAddress, proxy)
    secondary.connectStart(call, inetSocketAddress, proxy)
  }

  override fun secureConnectStart(call: Call) {
    primary.secureConnectStart(call)
    secondary.secureConnectStart(call)
  }

  override fun secureConnectEnd(call: Call, handshake: Handshake?) {
    primary.secureConnectEnd(call, handshake)
    secondary.secureConnectEnd(call, handshake)
  }

  override fun connectEnd(
    call: Call,
    inetSocketAddress: InetSocketAddress,
    proxy: Proxy,
    protocol: Protocol?
  ) {
    primary.connectEnd(call, inetSocketAddress, proxy, protocol)
    secondary.connectEnd(call, inetSocketAddress, proxy, protocol)
  }

  override fun connectFailed(
    call: Call,
    inetSocketAddress: InetSocketAddress,
    proxy: Proxy,
    protocol: Protocol?,
    ioe: IOException
  ) {
    primary.connectFailed(call, inetSocketAddress, proxy, protocol, ioe)
    secondary.connectFailed(call, inetSocketAddress, proxy, protocol, ioe)
  }

  override fun connectionAcquired(call: Call, connection: Connection) {
    primary.connectionAcquired(call, connection)
    secondary.connectionAcquired(call, connection)
  }

  override fun connectionReleased(call: Call, connection: Connection) {
    primary.connectionReleased(call, connection)
    secondary.connectionReleased(call, connection)
  }

  override fun requestHeadersStart(call: Call) {
    primary.requestHeadersStart(call)
    secondary.requestHeadersStart(call)
  }

  override fun requestHeadersEnd(call: Call, request: Request) {
    primary.requestHeadersEnd(call, request)
    secondary.requestHeadersEnd(call, request)
  }

  override fun requestBodyStart(call: Call) {
    primary.requestBodyStart(call)
    secondary.requestBodyStart(call)
  }

  override fun requestBodyEnd(call: Call, byteCount: Long) {
    primary.requestBodyEnd(call, byteCount)
    secondary.requestBodyEnd(call, byteCount)
  }

  override fun requestFailed(call: Call, ioe: IOException) {
    primary.requestFailed(call, ioe)
    secondary.requestFailed(call, ioe)
  }

  override fun responseHeadersStart(call: Call) {
    primary.responseHeadersStart(call)
    secondary.responseHeadersStart(call)
  }

  override fun responseHeadersEnd(call: Call, response: Response) {
    primary.responseHeadersEnd(call, response)
    secondary.responseHeadersEnd(call, response)
  }

  override fun responseBodyStart(call: Call) {
    primary.responseBodyStart(call)
    secondary.responseBodyStart(call)
  }

  override fun responseBodyEnd(call: Call, byteCount: Long) {
    primary.responseBodyEnd(call, byteCount)
    secondary.responseBodyEnd(call, byteCount)
  }

  override fun responseFailed(call: Call, ioe: IOException) {
    primary.responseFailed(call, ioe)
    secondary.responseFailed(call, ioe)
  }

  override fun cacheHit(call: Call, response: Response) {
    primary.cacheHit(call, response)
    secondary.cacheHit(call, response)
  }

  override fun cacheMiss(call: Call) {
    primary.cacheMiss(call)
    secondary.cacheMiss(call)
  }

  override fun cacheConditionalHit(call: Call, cachedResponse: Response) {
    primary.cacheConditionalHit(call, cachedResponse)
    secondary.cacheConditionalHit(call, cachedResponse)
  }

  override fun satisfactionFailure(call: Call, response: Response) {
    primary.satisfactionFailure(call, response)
    secondary.satisfactionFailure(call, response)
  }

  override fun canceled(call: Call) {
    primary.canceled(call)
    secondary.canceled(call)
  }

  override fun callEnd(call: Call) {
    primary.callEnd(call)
    secondary.callEnd(call)
  }

  override fun callFailed(call: Call, ioe: IOException) {
    primary.callFailed(call, ioe)
    secondary.callFailed(call, ioe)
  }
}

private class NativeOkHttpEventListener(
  private val call: Call
) : EventListener() {
  override fun proxySelectStart(call: Call, url: okhttp3.HttpUrl) {
    InAppDebuggerNativeNetworkCapture.appendEvent(call, eventText = "proxy select ${url.host}")
  }

  override fun proxySelectEnd(call: Call, url: okhttp3.HttpUrl, proxies: List<Proxy>) {
    InAppDebuggerNativeNetworkCapture.appendEvent(
      call,
      eventText = "proxy resolved ${proxies.joinToString { it.type().name }}"
    )
  }

  override fun dnsStart(call: Call, domainName: String) {
    InAppDebuggerNativeNetworkCapture.appendEvent(call, eventText = "dns start $domainName")
  }

  override fun dnsEnd(call: Call, domainName: String, inetAddressList: List<java.net.InetAddress>) {
    InAppDebuggerNativeNetworkCapture.appendEvent(
      call,
      eventText = "dns end $domainName ${inetAddressList.size} addresses"
    )
  }

  override fun connectStart(call: Call, inetSocketAddress: InetSocketAddress, proxy: Proxy) {
    InAppDebuggerNativeNetworkCapture.appendEvent(
      call,
      eventText = "connect start ${inetSocketAddress.hostString}:${inetSocketAddress.port} via ${proxy.type().name}"
    )
  }

  override fun secureConnectStart(call: Call) {
    InAppDebuggerNativeNetworkCapture.appendEvent(call, eventText = "tls start")
  }

  override fun secureConnectEnd(call: Call, handshake: Handshake?) {
    val tlsVersion = handshake?.tlsVersion?.javaName ?: "unknown"
    val cipherSuite = handshake?.cipherSuite?.javaName ?: "unknown"
    InAppDebuggerNativeNetworkCapture.appendEvent(
      call,
      eventText = "tls end $tlsVersion $cipherSuite"
    )
  }

  override fun connectEnd(
    call: Call,
    inetSocketAddress: InetSocketAddress,
    proxy: Proxy,
    protocol: Protocol?
  ) {
    InAppDebuggerNativeNetworkCapture.appendEvent(
      call,
      eventText = "connect end ${normalizeProtocol(protocol) ?: "unknown"}"
    )
  }

  override fun connectFailed(
    call: Call,
    inetSocketAddress: InetSocketAddress,
    proxy: Proxy,
    protocol: Protocol?,
    ioe: IOException
  ) {
    InAppDebuggerNativeNetworkCapture.appendEvent(
      call,
      eventText = "connect failed ${ioe.message ?: ioe.javaClass.simpleName}"
    )
  }

  override fun connectionAcquired(call: Call, connection: Connection) {
    InAppDebuggerNativeNetworkCapture.appendEvent(
      call,
      eventText = "connection acquired ${normalizeProtocol(connection.protocol()) ?: "unknown"}"
    )
  }

  override fun connectionReleased(call: Call, connection: Connection) {
    InAppDebuggerNativeNetworkCapture.appendEvent(call, eventText = "connection released")
  }

  override fun requestHeadersStart(call: Call) {
    InAppDebuggerNativeNetworkCapture.appendEvent(call, eventText = "request headers start")
  }

  override fun requestHeadersEnd(call: Call, request: Request) {
    InAppDebuggerNativeNetworkCapture.appendEvent(call, eventText = "request headers end")
  }

  override fun requestBodyStart(call: Call) {
    InAppDebuggerNativeNetworkCapture.appendEvent(call, eventText = "request body start")
  }

  override fun requestBodyEnd(call: Call, byteCount: Long) {
    InAppDebuggerNativeNetworkCapture.appendEvent(
      call,
      eventText = "request body end ${formatPreviewByteCount(byteCount)}"
    ) {
      requestBodyBytesObserved = byteCount
    }
  }

  override fun requestFailed(call: Call, ioe: IOException) {
    InAppDebuggerNativeNetworkCapture.appendEvent(
      call,
      eventText = "request failed ${ioe.message ?: ioe.javaClass.simpleName}"
    )
  }

  override fun responseHeadersStart(call: Call) {
    InAppDebuggerNativeNetworkCapture.appendEvent(call, eventText = "response headers start")
  }

  override fun responseHeadersEnd(call: Call, response: Response) {
    InAppDebuggerNativeNetworkCapture.appendEvent(
      call,
      eventText = "response headers end ${response.code}"
    ) {
      status = response.code
      if (kind == "websocket") {
        protocol = response.header("Sec-WebSocket-Protocol") ?: protocol
      }
    }
  }

  override fun responseBodyStart(call: Call) {
    InAppDebuggerNativeNetworkCapture.appendEvent(call, eventText = "response body start")
  }

  override fun responseBodyEnd(call: Call, byteCount: Long) {
    InAppDebuggerNativeNetworkCapture.appendEvent(
      call,
      eventText = "response body end ${formatPreviewByteCount(byteCount)}"
    ) {
      responseBodyBytesObserved = byteCount
      if (responseSize == null && byteCount >= 0L) {
        responseSize = byteCount.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
      }
    }
  }

  override fun responseFailed(call: Call, ioe: IOException) {
    InAppDebuggerNativeNetworkCapture.appendEvent(
      call,
      eventText = "response failed ${ioe.message ?: ioe.javaClass.simpleName}"
    )
  }

  override fun cacheHit(call: Call, response: Response) {
    InAppDebuggerNativeNetworkCapture.appendEvent(call, eventText = "cache hit ${response.code}")
  }

  override fun cacheMiss(call: Call) {
    InAppDebuggerNativeNetworkCapture.appendEvent(call, eventText = "cache miss")
  }

  override fun cacheConditionalHit(call: Call, cachedResponse: Response) {
    InAppDebuggerNativeNetworkCapture.appendEvent(
      call,
      eventText = "cache conditional hit ${cachedResponse.code}"
    )
  }

  override fun satisfactionFailure(call: Call, response: Response) {
    InAppDebuggerNativeNetworkCapture.appendEvent(
      call,
      eventText = "cache satisfaction failure ${response.code}"
    )
  }

  override fun canceled(call: Call) {
    val timestamp = System.currentTimeMillis()
    InAppDebuggerNativeNetworkCapture.finalizeFromListener(call, timestamp) {
      state = "error"
      error = error ?: "Canceled"
      endedAt = endedAt ?: timestamp
      durationMs = durationMs ?: max(0L, timestamp - startedAt)
      if (!events.lastOrNull().orEmpty().contains("canceled")) {
        events += "[${formatNativeNetworkClock(timestamp)}] canceled"
        dirty = true
      }
    }
  }

  override fun callEnd(call: Call) {
    val timestamp = System.currentTimeMillis()
    InAppDebuggerNativeNetworkCapture.finalizeFromListener(call, timestamp) {
      if (kind == "http" && endedAt == null) {
        endedAt = timestamp
        durationMs = max(0L, timestamp - startedAt)
      }
      if (kind == "http" && state == "pending") {
        state = if ((status ?: 0) >= 400) "error" else "success"
      }
      if (events.lastOrNull().orEmpty().contains("call end").not()) {
        events += "[${formatNativeNetworkClock(timestamp)}] call end"
        dirty = true
      }
    }
  }

  override fun callFailed(call: Call, ioe: IOException) {
    val timestamp = System.currentTimeMillis()
    InAppDebuggerNativeNetworkCapture.finalizeFromListener(call, timestamp) {
      state = "error"
      error = error ?: ioe.message ?: ioe.javaClass.simpleName
      endedAt = endedAt ?: timestamp
      durationMs = durationMs ?: max(0L, timestamp - startedAt)
      if (events.lastOrNull().orEmpty().contains("call failed").not()) {
        events += "[${formatNativeNetworkClock(timestamp)}] call failed ${error ?: "Request failed"}"
        dirty = true
      }
    }
  }
}

private data class ResponseBodyPreview(
  val preview: String?,
  val size: Int?
)

private fun isWebSocketUpgrade(request: Request): Boolean {
  val upgrade = request.header("Upgrade")?.lowercase(Locale.ROOT)
  return upgrade == "websocket" || request.header("Sec-WebSocket-Key") != null
}

private inline fun <reified T> Class<*>.readObjectField(name: String, receiver: Any): T? {
  val field = getDeclaredField(name)
  field.isAccessible = true
  @Suppress("UNCHECKED_CAST")
  return field.get(receiver) as? T
}

private inline fun <reified T> Class<*>.readStaticField(name: String): T? {
  val field = getDeclaredField(name)
  field.isAccessible = true
  @Suppress("UNCHECKED_CAST")
  return field.get(null) as? T
}

private fun Class<*>.writeObjectField(name: String, receiver: Any, value: Any?) {
  val field = getDeclaredField(name)
  field.isAccessible = true
  field.set(receiver, value)
}

private fun Headers.toDebugHeaderMap(): Map<String, String> {
  if (size == 0) {
    return emptyMap()
  }
  return names()
    .sortedBy { it.lowercase(Locale.ROOT) }
    .associateWith { name -> values(name).joinToString(", ") }
}

private fun RequestBody?.previewRequestBody(contentTypeHeader: String?): String? {
  val body = this ?: return null
  val contentLength = runCatching { body.contentLength() }.getOrDefault(-1L)
  val contentType = contentTypeHeader ?: body.contentType()?.toString()

  if (body.isDuplex()) {
    return "[duplex body]"
  }
  if (body.isOneShot()) {
    return omittedBodyPreview("one-shot body", contentType, contentLength)
  }
  if (contentLength < 0L) {
    return omittedBodyPreview("streamed body", contentType, contentLength)
  }
  if (contentLength > MAX_BODY_PREVIEW_BYTES) {
    return omittedBodyPreview("body omitted", contentType, contentLength)
  }

  return runCatching {
    val buffer = Buffer()
    body.writeTo(buffer)
    decodeBodyPreview(
      data = buffer.readByteArray(),
      contentType = contentType,
      declaredLength = contentLength
    )
  }.getOrElse { error ->
    "[request body unavailable: ${error.message ?: error.javaClass.simpleName}]"
  }
}

private fun Response.previewResponseBody(): ResponseBodyPreview {
  val body = body ?: return ResponseBodyPreview(preview = null, size = null)
  val contentLength = runCatching { body.contentLength() }.getOrDefault(-1L)
  val contentType = header("Content-Type") ?: body.contentType()?.toString()

  return runCatching {
    val peeked = peekBody(MAX_BODY_PREVIEW_BYTES)
    val bytes = peeked.bytes()
    val normalizedSize = contentLength.takeIf { it >= 0L }?.coerceAtMost(Int.MAX_VALUE.toLong())?.toInt()
    ResponseBodyPreview(
      preview = decodeBodyPreview(bytes, contentType, contentLength),
      size = normalizedSize ?: bytes.size
    )
  }.getOrElse { error ->
    ResponseBodyPreview(
      preview = "[response body unavailable: ${error.message ?: error.javaClass.simpleName}]",
      size = contentLength.takeIf { it >= 0L }?.coerceAtMost(Int.MAX_VALUE.toLong())?.toInt()
    )
  }
}

private fun omittedBodyPreview(label: String, contentType: String?, contentLength: Long): String {
  val suffix = buildList {
    contentType?.takeIf { it.isNotBlank() }?.let { add("content-type=$it") }
    if (contentLength >= 0L) {
      add("size=${formatPreviewByteCount(contentLength)}")
    }
  }.joinToString(", ")
  return if (suffix.isBlank()) {
    "[$label]"
  } else {
    "[$label: $suffix]"
  }
}

private fun buildRedirectChain(response: Response): List<Response> {
  val chain = ArrayList<Response>(MAX_EVENT_REDIRECTS)
  var current = response.priorResponse
  while (current != null && chain.size < MAX_EVENT_REDIRECTS) {
    chain += current
    current = current.priorResponse
  }
  chain.reverse()
  return chain
}

private fun decodeBodyPreview(
  data: ByteArray,
  contentType: String?,
  declaredLength: Long
): String? {
  if (data.isEmpty()) {
    return null
  }

  val loweredContentType = contentType?.lowercase(Locale.ROOT).orEmpty()
  if (isLikelyBinaryContentType(loweredContentType)) {
    return binaryPreview(data, declaredLength)
  }

  val buffer = Buffer().write(data)
  if (!buffer.isProbablyUtf8()) {
    return binaryPreview(data, declaredLength)
  }

  val text = data.toString(Charsets.UTF_8)
    .replace("\r\n", "\n")
    .replace('\r', '\n')

  val suffix =
    if (declaredLength > data.size.toLong()) {
      "\n...[truncated at ${formatPreviewByteCount(data.size.toLong())}]"
    } else {
      ""
    }
  return text + suffix
}

private fun binaryPreview(data: ByteArray, declaredLength: Long): String {
  val previewBytes = data
    .take(MAX_BINARY_PREVIEW_BYTES)
    .joinToString(" ") { byte -> "%02X".format(Locale.ROOT, byte.toInt() and 0xFF) }
  val truncatedSuffix =
    if (declaredLength > data.size.toLong()) {
      " ..."
    } else {
      ""
    }
  val sizeLabel =
    if (declaredLength >= 0L) {
      formatPreviewByteCount(declaredLength)
    } else {
      formatPreviewByteCount(data.size.toLong())
    }
  return "[binary $sizeLabel]\n$previewBytes$truncatedSuffix"
}

private fun normalizedResponseType(contentType: String?): String? {
  val mimeType = contentType?.lowercase(Locale.ROOT).orEmpty()
  if (mimeType.isBlank()) {
    return null
  }
  return when {
    mimeType.contains("json") -> "json"
    mimeType.startsWith("text/") -> "text"
    mimeType.startsWith("image/") ||
      mimeType.startsWith("audio/") ||
      mimeType.startsWith("video/") ||
      mimeType.contains("application/octet-stream") -> "binary"
    else -> mimeType
  }
}

private fun isLikelyBinaryContentType(contentType: String): Boolean {
  if (contentType.isBlank()) {
    return false
  }
  return contentType.startsWith("image/") ||
    contentType.startsWith("audio/") ||
    contentType.startsWith("video/") ||
    contentType.contains("application/octet-stream") ||
    contentType.contains("application/zip") ||
    contentType.contains("application/pdf")
}

private fun normalizeProtocol(protocol: Protocol?): String? {
  return when (protocol) {
    null -> null
    Protocol.HTTP_1_0 -> "http/1.0"
    Protocol.HTTP_1_1 -> "http/1.1"
    Protocol.HTTP_2 -> "h2"
    Protocol.H2_PRIOR_KNOWLEDGE -> "h2-prior-knowledge"
    Protocol.QUIC -> "quic"
    Protocol.SPDY_3 -> "spdy/3"
  }
}

private fun formatPreviewByteCount(byteCount: Long): String {
  if (byteCount < 1024L) {
    return "${max(0L, byteCount)} B"
  }
  val kilobytes = byteCount / 1024.0
  if (kilobytes < 1024.0) {
    return String.format(Locale.ROOT, "%.1f KB", kilobytes)
  }
  val megabytes = kilobytes / 1024.0
  return String.format(Locale.ROOT, "%.1f MB", megabytes)
}

private fun formatNativeNetworkClock(timestampMillis: Long): String {
  return createNativeDebugLogEntry(
    type = "debug",
    message = "",
    timestampMillis = timestampMillis
  ).timestamp
}

private fun Buffer.isProbablyUtf8(): Boolean {
  return try {
    val prefix = Buffer()
    val byteCount = minOf(size, 64L)
    copyTo(prefix, 0, byteCount)
    repeat(16) {
      if (prefix.exhausted()) {
        return true
      }
      val codePoint = prefix.readUtf8CodePoint()
      if (Character.isISOControl(codePoint) && !Character.isWhitespace(codePoint)) {
        return false
      }
    }
    true
  } catch (_: Throwable) {
    false
  }
}
