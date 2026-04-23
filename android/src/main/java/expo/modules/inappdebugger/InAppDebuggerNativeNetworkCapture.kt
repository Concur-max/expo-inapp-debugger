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
import kotlin.math.roundToLong
import okhttp3.Call
import okhttp3.Connection
import okhttp3.EventListener
import okhttp3.Handshake
import okhttp3.Headers
import okhttp3.Interceptor
import okhttp3.MediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.Response
import okhttp3.ResponseBody
import okio.Buffer
import okio.BufferedSource
import okio.BufferedSink
import okio.ForwardingSink
import okio.ForwardingSource
import okio.buffer

private const val NATIVE_HTTP_ID_PREFIX = "native_http_"
private const val NATIVE_WS_ID_PREFIX = "native_ws_"
private const val MAX_BODY_PREVIEW_BYTES = 32_000L
private const val MAX_BINARY_PREVIEW_BYTES = 48
private const val MAX_EVENT_REDIRECTS = 8
private const val MAX_EVENT_LINES = 48
private const val LIVE_UPDATE_THROTTLE_MS = 120L
private val HEX_DIGITS = "0123456789ABCDEF".toCharArray()
private const val REACT_NATIVE_JS_REQUEST_ORIGIN = "js"

private class RequestOriginTag(val value: String)

private val reactNativeJsRequestOriginTag = RequestOriginTag(REACT_NATIVE_JS_REQUEST_ORIGIN)
private val reactNativeRequestMarkerInterceptor = ReactNativeRequestMarkerInterceptor()

object InAppDebuggerNativeNetworkCapture {
  private val lock = Any()
  private val requestCounter = AtomicLong(0)
  private val interceptor = NativeOkHttpCaptureInterceptor()

  private var appContextRef: WeakReference<Context>? = null
  @Volatile private var enabled = false
  @Volatile private var hooksInstalled = false
  @Volatile private var livePanelActive = false
  private var panelRequestedActive = false
  private val activeCalls = mutableMapOf<Call, NativeOkHttpCallState>()

  fun applyConfigIfNeeded(context: Context?, config: DebugConfig) {
    val nextEnabled = config.enabled && config.enableNetworkTab && config.enableNativeNetwork
    var shouldApply = true
    synchronized(lock) {
      if (!nextEnabled && !enabled && !hooksInstalled && activeCalls.isEmpty() && !panelRequestedActive) {
        shouldApply = false
      }
    }

    if (!shouldApply) {
      return
    }
    applyConfig(context, config)
  }

  fun applyConfig(context: Context?, config: DebugConfig) {
    var shouldRefreshVisibleEntries = false
    synchronized(lock) {
      if (context != null) {
        appContextRef = WeakReference(context.applicationContext)
      }
      val wasLivePanelActive = livePanelActive
      enabled = config.enabled && config.enableNetworkTab && config.enableNativeNetwork
      if (enabled) {
        if (!hooksInstalled) {
          installHooksLocked()
        }
      } else {
        activeCalls.clear()
      }
      livePanelActive = enabled && panelRequestedActive
      shouldRefreshVisibleEntries = livePanelActive && !wasLivePanelActive
    }
    if (shouldRefreshVisibleEntries) {
      refreshVisibleEntries()
    }
  }

  fun shutdown() {
    synchronized(lock) {
      enabled = false
      livePanelActive = false
      panelRequestedActive = false
      activeCalls.clear()
    }
  }

  fun setPanelActive(active: Boolean) {
    var shouldRefreshVisibleEntries = false
    synchronized(lock) {
      val wasLivePanelActive = livePanelActive
      panelRequestedActive = active
      livePanelActive = enabled && panelRequestedActive
      shouldRefreshVisibleEntries = livePanelActive && !wasLivePanelActive
    }
    if (shouldRefreshVisibleEntries) {
      refreshVisibleEntries()
    }
  }

  fun refreshVisibleEntries() {
    val entries = synchronized(lock) {
      if (!livePanelActive || activeCalls.isEmpty()) {
        return
      }

      val emissionTimestamp = System.currentTimeMillis()
      val snapshot = ArrayList<DebugNetworkEntry>(activeCalls.size)
      activeCalls.values.forEach { state ->
        state.lastStoreEmissionAt = emissionTimestamp
        snapshot += state.toEntryLocked()
      }
      snapshot
    }
    entries.forEach(InAppDebuggerStore::upsertNetworkEntry)
  }

  internal fun shouldCaptureLivePayloadPreview(): Boolean = livePanelActive

  fun applyTo(builder: OkHttpClient.Builder): OkHttpClient.Builder {
    val currentInterceptors = builder.interceptors()
    if (currentInterceptors.none { it === interceptor || it is NativeOkHttpCaptureInterceptor }) {
      builder.addInterceptor(interceptor)
    }
    val existingFactory = resolveBuilderEventListenerFactory(builder)
    builder.eventListenerFactory(compositeEventListenerFactory(existingFactory))
    return builder
  }

  fun applyToReactNativeBuilder(builder: OkHttpClient.Builder): OkHttpClient.Builder {
    val currentInterceptors = builder.interceptors()
    if (
      currentInterceptors.none {
        it === reactNativeRequestMarkerInterceptor || it is ReactNativeRequestMarkerInterceptor
      }
    ) {
      val captureInterceptorIndex =
        currentInterceptors.indexOfFirst {
          it === interceptor || it is NativeOkHttpCaptureInterceptor
        }
      if (captureInterceptorIndex >= 0) {
        currentInterceptors.add(captureInterceptorIndex, reactNativeRequestMarkerInterceptor)
      } else {
        builder.addInterceptor(reactNativeRequestMarkerInterceptor)
      }
    }
    return applyTo(builder)
  }

  internal fun shouldObserve(request: Request): Boolean {
    if (!enabled) {
      return false
    }

    return isSupportedNativeNetworkScheme(request.url.scheme)
  }

  internal fun shouldCapture(request: Request): Boolean {
    if (!shouldObserve(request)) {
      return false
    }

    // RN JS requests are marked explicitly so native clients that also use numeric tags
    // still show up in the native network feed.
    if (request.isReactNativeJsRequest()) {
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
      prepareEntryForStoreLocked(
        state = state,
        timestamp = state.updatedAt,
        policy = StoreEmissionPolicy.VisibleImmediate
      )
    }
    entry?.let(InAppDebuggerStore::upsertNetworkEntry)
  }

  internal fun captureRequestBodyPreview(
    call: Call,
    preview: String?,
    observedByteCount: Long
  ) {
    val entry = synchronized(lock) {
      val state = activeCalls[call] ?: return@synchronized null
      if (observedByteCount > 0L) {
        state.requestBodyBytesObserved = max(state.requestBodyBytesObserved ?: 0L, observedByteCount)
      }

      var changed = false
      if (preview != null && preview != state.requestBody) {
        state.requestBody = preview
        state.dirty = true
        changed = true
      }

      if (!changed || !state.startEmitted || state.state != "pending") {
        return@synchronized null
      }

      prepareEntryForStoreLocked(
        state = state,
        timestamp = state.updatedAt,
        policy = StoreEmissionPolicy.VisibleThrottled
      )
    }
    entry?.let(InAppDebuggerStore::upsertNetworkEntry)
  }

  internal fun emitResponse(call: Call, request: Request, response: Response) {
    val entry = synchronized(lock) {
      val state = activeCalls.getOrPut(call) { createCallStateLocked(request) }
      val timestamp = System.currentTimeMillis()
      val responseContentLength = response.body.contentLengthOrNull()

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
        state.protocol = normalizeProtocol(response.protocol)
        state.responseType = normalizedResponseType(state.responseContentType)
        state.responseSize =
          responseContentLength?.coerceAtMost(Int.MAX_VALUE.toLong())?.toInt()
            ?: state.responseBodyBytesObserved?.coerceAtMost(Int.MAX_VALUE.toLong())?.toInt()
        state.state = if (response.code >= 400) "error" else "success"
        if (response.body == null || responseContentLength == 0L) {
          state.endedAt = timestamp
          state.durationMs = max(0L, timestamp - state.startedAt)
        }
      }

      prepareEntryForStoreLocked(
        state = state,
        timestamp = timestamp,
        policy = StoreEmissionPolicy.VisibleThrottled
      )
    }
    entry?.let(InAppDebuggerStore::upsertNetworkEntry)
  }

  internal fun captureResponseBodyPreview(
    call: Call,
    preview: String?,
    observedByteCount: Long,
    declaredByteCount: Long?
  ) {
    val entry = synchronized(lock) {
      val state = activeCalls[call] ?: return@synchronized null

      var changed = false
      if (observedByteCount > 0L) {
        val nextObserved = max(state.responseBodyBytesObserved ?: 0L, observedByteCount)
        if (nextObserved != state.responseBodyBytesObserved) {
          state.responseBodyBytesObserved = nextObserved
          changed = true
        }
      }

      val normalizedSize =
        declaredByteCount?.takeIf { it >= 0L }?.coerceAtMost(Int.MAX_VALUE.toLong())?.toInt()
          ?: state.responseBodyBytesObserved?.coerceAtMost(Int.MAX_VALUE.toLong())?.toInt()
      if (normalizedSize != null && normalizedSize != state.responseSize) {
        state.responseSize = normalizedSize
        changed = true
      }

      if (preview != null && preview != state.responseBody) {
        state.responseBody = preview
        changed = true
      }

      if (!changed || !state.startEmitted) {
        return@synchronized null
      }

      state.dirty = true
      prepareEntryForStoreLocked(
        state = state,
        timestamp = state.updatedAt,
        policy = StoreEmissionPolicy.VisibleThrottled
      )
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
      prepareEntryForStoreLocked(
        state = state,
        timestamp = timestamp,
        policy = StoreEmissionPolicy.Always
      )
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
      prepareEntryForStoreLocked(
        state = state,
        timestamp = timestamp,
        policy = StoreEmissionPolicy.Always
      )
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
    val timelineSequence = requestCounter.incrementAndGet()
    val method =
      if (isWebSocket) {
        webSocketMethod(request.url.toString())
      } else {
        request.method.uppercase(Locale.ROOT)
      }
    val state = NativeOkHttpCallState(
      requestId = buildRequestId(isWebSocket, startedAt, timelineSequence),
      kind = if (isWebSocket) "websocket" else "http",
      method = method,
      url = request.url.toString(),
      startedAt = startedAt,
      updatedAt = startedAt,
      timelineSequence = timelineSequence,
      requestHeaders = request.headers.toDebugHeaderMap(),
      requestedProtocols = request.header("Sec-WebSocket-Protocol")?.takeIf { it.isNotBlank() },
      state = if (isWebSocket) "connecting" else "pending"
    )
    appendEventLocked(state, startedAt, "start ${state.method} ${state.url}")
    return state
  }

  private fun prepareEntryForStoreLocked(
    state: NativeOkHttpCallState,
    timestamp: Long,
    policy: StoreEmissionPolicy
  ): DebugNetworkEntry? {
    if (!shouldEmitToStoreLocked(state.lastStoreEmissionAt, timestamp, policy)) {
      return null
    }
    state.lastStoreEmissionAt = timestamp
    return state.toEntryLocked()
  }

  private fun shouldEmitToStoreLocked(
    lastEmissionAt: Long,
    timestamp: Long,
    policy: StoreEmissionPolicy
  ): Boolean {
    return when (policy) {
      StoreEmissionPolicy.Always -> true
      StoreEmissionPolicy.VisibleImmediate -> livePanelActive
      StoreEmissionPolicy.VisibleThrottled -> {
        livePanelActive && (timestamp - lastEmissionAt >= LIVE_UPDATE_THROTTLE_MS)
      }
    }
  }

  private fun buildRequestId(
    isWebSocket: Boolean,
    startedAt: Long,
    timelineSequence: Long
  ): String {
    val prefix = if (isWebSocket) NATIVE_WS_ID_PREFIX else NATIVE_HTTP_ID_PREFIX
    return prefix + startedAt + "_" + timelineSequence
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
    if (state.eventCount >= MAX_EVENT_LINES) {
      if (!state.truncatedEvents) {
        appendSerializedNetworkEventLine(state, timestamp, "...more events omitted...")
        state.truncatedEvents = true
      }
      return
    }
    appendSerializedNetworkEventLine(state, timestamp, eventText)
    state.eventCount += 1
  }

  private fun webSocketMethod(url: String): String {
    return if (url.startsWith("wss:", ignoreCase = true) || url.startsWith("https:", ignoreCase = true)) {
      "WSS"
    } else {
      "WS"
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
      applyToReactNativeBuilder(builder)
    }
  }

  private enum class StoreEmissionPolicy {
    VisibleImmediate,
    VisibleThrottled,
    Always
  }
}

internal data class NativeOkHttpCallState(
  val requestId: String,
  val kind: String,
  var method: String,
  var url: String,
  val startedAt: Long,
  var updatedAt: Long,
  val timelineSequence: Long,
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
  var serializedEvents: String? = null,
  var serializedEventsBuilder: StringBuilder? = null,
  var eventCount: Int = 0,
  var lastEventText: String = "",
  var startEmitted: Boolean = false,
  var dirty: Boolean = true,
  var eventsChanged: Boolean = false,
  var redirectsRecorded: Boolean = false,
  var truncatedEvents: Boolean = false,
  var lastStoreEmissionAt: Long = 0L
) {
  fun toEntryLocked(): DebugNetworkEntry {
    dirty = false
    if (eventsChanged) {
      serializedEvents = serializedEventsBuilder?.toString()
      eventsChanged = false
    }
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
      events = serializedEvents,
      timelineSequence = timelineSequence
    )
  }
}

private fun appendSerializedNetworkEventLine(
  state: NativeOkHttpCallState,
  timestamp: Long,
  eventText: String
) {
  val builder = state.serializedEventsBuilder ?: StringBuilder(256).also {
    state.serializedEventsBuilder = it
  }
  if (builder.isNotEmpty()) {
    builder.append('\n')
  }
  builder.append('[')
  builder.append(formatNativeNetworkClock(timestamp))
  builder.append("] ")
  builder.append(eventText)
  state.lastEventText = eventText
  state.eventsChanged = true
  state.dirty = true
}

private class NativeOkHttpCaptureInterceptor : Interceptor {
  override fun intercept(chain: Interceptor.Chain): Response {
    val originalRequest = chain.request()
    if (!InAppDebuggerNativeNetworkCapture.shouldCapture(originalRequest)) {
      return chain.proceed(originalRequest)
    }

    val call = chain.call()
    val request = instrumentRequestBody(originalRequest, call)
    InAppDebuggerNativeNetworkCapture.ensureCallState(call, request)
    InAppDebuggerNativeNetworkCapture.emitPending(call, request, null)

    return try {
      val response = instrumentResponseBody(chain.proceed(request), call)
      InAppDebuggerNativeNetworkCapture.emitResponse(call, request, response)
      response
    } catch (throwable: Throwable) {
      InAppDebuggerNativeNetworkCapture.emitFailure(call, request, throwable)
      throw throwable
    }
  }
}

private fun instrumentRequestBody(request: Request, call: Call): Request {
  val body = request.body ?: return request
  if (body is PreviewingRequestBody || isWebSocketUpgrade(request)) {
    return request
  }
  if (!InAppDebuggerNativeNetworkCapture.shouldCaptureLivePayloadPreview()) {
    return request
  }

  val contentTypeHeader = request.header("Content-Type") ?: body.contentType()?.toString()
  if (!shouldCaptureBodyPreview(contentTypeHeader, body.contentLengthOrNull())) {
    return request
  }

  return request.newBuilder()
    .method(
      request.method,
      PreviewingRequestBody(body, contentTypeHeader) { preview ->
        InAppDebuggerNativeNetworkCapture.captureRequestBodyPreview(
          call = call,
          preview = preview.preview,
          observedByteCount = preview.observedByteCount
        )
      }
    )
    .build()
}

private class PreviewingRequestBody(
  private val delegate: RequestBody,
  private val contentTypeHeader: String?,
  private val onPreviewCaptured: (RequestBodyPreviewCapture) -> Unit
) : RequestBody() {
  override fun contentType() = delegate.contentType()

  override fun contentLength(): Long = delegate.contentLength()

  override fun isDuplex(): Boolean = delegate.isDuplex()

  override fun isOneShot(): Boolean = delegate.isOneShot()

  override fun writeTo(sink: BufferedSink) {
    val capture = RequestBodyPreviewRecorder(contentTypeHeader ?: delegate.contentType()?.toString())
    val forwardingSink =
      object : ForwardingSink(sink) {
        override fun write(source: Buffer, byteCount: Long) {
          capture.record(source, byteCount)
          super.write(source, byteCount)
        }
      }
    val bufferedSink = forwardingSink.buffer()
    var published = false

    fun publishCapture() {
      if (!published) {
        published = true
        onPreviewCaptured(capture.build())
      }
    }

    try {
      delegate.writeTo(bufferedSink)
      bufferedSink.flush()
      publishCapture()
    } catch (error: Throwable) {
      publishCapture()
      throw error
    }
  }
}

private class RequestBodyPreviewRecorder(
  private val contentType: String?
) {
  private val previewBuffer = Buffer()
  private var observedByteCount = 0L

  fun record(source: Buffer, byteCount: Long) {
    if (byteCount <= 0L) {
      return
    }

    observedByteCount += byteCount
    val remainingPreviewBytes = MAX_BODY_PREVIEW_BYTES - previewBuffer.size
    if (remainingPreviewBytes <= 0L) {
      return
    }

    source.copyTo(previewBuffer, 0L, minOf(byteCount, remainingPreviewBytes))
  }

  fun build(): RequestBodyPreviewCapture {
    val bytes = previewBuffer.readByteArray()
    return RequestBodyPreviewCapture(
      preview =
        decodeBodyPreview(
          data = bytes,
          contentType = contentType,
          declaredLength = observedByteCount
        ),
      observedByteCount = observedByteCount
    )
  }
}

private data class RequestBodyPreviewCapture(
  val preview: String?,
  val observedByteCount: Long
)

private fun instrumentResponseBody(response: Response, call: Call): Response {
  val body = response.body ?: return response
  if (body is PreviewingResponseBody || isWebSocketUpgrade(response.request)) {
    return response
  }
  if (!InAppDebuggerNativeNetworkCapture.shouldCaptureLivePayloadPreview()) {
    return response
  }

  val contentTypeHeader = response.header("Content-Type") ?: body.contentType()?.toString()
  val contentLength = body.contentLengthOrNull()
  if (!shouldCaptureBodyPreview(contentTypeHeader, contentLength)) {
    return response
  }

  return response.newBuilder()
    .body(
      PreviewingResponseBody(
        delegate = body,
        contentTypeHeader = contentTypeHeader
      ) { preview ->
        InAppDebuggerNativeNetworkCapture.captureResponseBodyPreview(
          call = call,
          preview = preview.preview,
          observedByteCount = preview.observedByteCount,
          declaredByteCount = preview.declaredByteCount
        )
      }
    )
    .build()
}

private class PreviewingResponseBody(
  private val delegate: ResponseBody,
  private val contentTypeHeader: String?,
  private val onPreviewCaptured: (ResponseBodyPreviewCapture) -> Unit
) : ResponseBody() {
  private val declaredContentLength = delegate.contentLengthOrNull()
  private val recorder = ResponseBodyPreviewRecorder(
    contentType = contentTypeHeader ?: delegate.contentType()?.toString(),
    declaredContentLength = declaredContentLength
  )
  private val upstreamSource by lazy(LazyThreadSafetyMode.NONE) { delegate.source() }
  private var wrappedSource: BufferedSource? = null
  private var published = false

  override fun contentType(): MediaType? = delegate.contentType()

  override fun contentLength(): Long = declaredContentLength ?: -1L

  override fun source(): BufferedSource {
    wrappedSource?.let { return it }

    val observingSource =
      object : ForwardingSource(upstreamSource) {
        override fun read(sink: Buffer, byteCount: Long): Long {
          return try {
            val read = super.read(sink, byteCount)
            when {
              read > 0L -> recorder.recordRead(sink, read)
              read == -1L -> publishPreview()
            }
            read
          } catch (error: Throwable) {
            publishPreview()
            throw error
          }
        }

        override fun close() {
          publishPreview()
          super.close()
        }
      }

    return observingSource.buffer().also {
      wrappedSource = it
    }
  }

  private fun publishPreview() {
    if (published) {
      return
    }
    published = true
    recorder.captureUnreadPrefix(upstreamSource)
    onPreviewCaptured(recorder.build())
  }
}

private class ResponseBodyPreviewRecorder(
  private val contentType: String?,
  private val declaredContentLength: Long?
) {
  private val previewBuffer = Buffer()
  private var observedByteCount = 0L

  fun recordRead(sink: Buffer, byteCount: Long) {
    if (byteCount <= 0L) {
      return
    }

    observedByteCount += byteCount
    val remainingPreviewBytes = MAX_BODY_PREVIEW_BYTES - previewBuffer.size
    if (remainingPreviewBytes <= 0L) {
      return
    }

    val startOffset = sink.size - byteCount
    sink.copyTo(previewBuffer, startOffset, minOf(byteCount, remainingPreviewBytes))
  }

  fun captureUnreadPrefix(source: BufferedSource) {
    val remainingPreviewBytes = MAX_BODY_PREVIEW_BYTES - previewBuffer.size
    if (remainingPreviewBytes <= 0L) {
      return
    }

    runCatching {
      val peekSource = source.peek()
      while (previewBuffer.size < MAX_BODY_PREVIEW_BYTES) {
        val read = peekSource.read(previewBuffer, MAX_BODY_PREVIEW_BYTES - previewBuffer.size)
        if (read <= 0L) {
          break
        }
      }
    }
  }

  fun build(): ResponseBodyPreviewCapture {
    val previewByteCount = previewBuffer.size
    val bytes = previewBuffer.readByteArray()
    val effectiveDeclaredLength =
      declaredContentLength?.takeIf { it >= 0L }
        ?: max(observedByteCount, previewByteCount)

    return ResponseBodyPreviewCapture(
      preview =
        decodeBodyPreview(
          data = bytes,
          contentType = contentType,
          declaredLength = effectiveDeclaredLength
        ),
      observedByteCount = observedByteCount,
      declaredByteCount = declaredContentLength?.takeIf { it >= 0L } ?: effectiveDeclaredLength
    )
  }
}

private data class ResponseBodyPreviewCapture(
  val preview: String?,
  val observedByteCount: Long,
  val declaredByteCount: Long?
)

private class InstrumentedEventListenerFactory(
  private val delegate: EventListener.Factory?
) : EventListener.Factory {
  override fun create(call: Call): EventListener {
    val delegateListener = delegate?.create(call) ?: EventListener.NONE
    val nativeListener =
      if (InAppDebuggerNativeNetworkCapture.shouldObserve(call.request())) {
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

private class ReactNativeRequestMarkerInterceptor : Interceptor {
  override fun intercept(chain: Interceptor.Chain): Response {
    val request = chain.request()
    if (request.isReactNativeJsRequest()) {
      return chain.proceed(request)
    }

    val markedRequest =
      request.newBuilder()
        .tag(RequestOriginTag::class.java, reactNativeJsRequestOriginTag)
        .build()
    return chain.proceed(markedRequest)
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
      eventText = "proxy resolved ${formatProxyTypes(proxies)}"
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
      if (!lastEventText.contains("canceled")) {
        appendSerializedNetworkEventLine(this, timestamp, "canceled")
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
      if (lastEventText.contains("call end").not()) {
        appendSerializedNetworkEventLine(this, timestamp, "call end")
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
      if (lastEventText.contains("call failed").not()) {
        appendSerializedNetworkEventLine(this, timestamp, "call failed ${error ?: "Request failed"}")
      }
    }
  }
}

private fun isWebSocketUpgrade(request: Request): Boolean {
  return request.header("Upgrade")?.equals("websocket", ignoreCase = true) == true ||
    request.header("Sec-WebSocket-Key") != null
}

private fun isSupportedNativeNetworkScheme(scheme: String?): Boolean {
  return scheme.equals("http", ignoreCase = true) ||
    scheme.equals("https", ignoreCase = true) ||
    scheme.equals("ws", ignoreCase = true) ||
    scheme.equals("wss", ignoreCase = true)
}

private fun Request.isReactNativeJsRequest(): Boolean {
  return tag(RequestOriginTag::class.java)?.value == REACT_NATIVE_JS_REQUEST_ORIGIN
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
  if (size == 1) {
    return mapOf(name(0) to value(0))
  }

  val result = LinkedHashMap<String, String>(size)
  for (index in 0 until size) {
    val name = name(index)
    val existing = result[name]
    result[name] =
      if (existing == null) {
        value(index)
      } else {
        "$existing, ${value(index)}"
      }
  }
  return result
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

  if (!data.isProbablyUtf8()) {
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
  val previewLength = minOf(data.size, MAX_BINARY_PREVIEW_BYTES)
  val previewBytes = StringBuilder(previewLength * 3)
  for (index in 0 until previewLength) {
    if (index > 0) {
      previewBytes.append(' ')
    }
    val value = data[index].toInt() and 0xFF
    previewBytes.append(HEX_DIGITS[value ushr 4])
    previewBytes.append(HEX_DIGITS[value and 0x0F])
  }
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
  val normalized = max(0L, byteCount)
  if (normalized < 1024L) {
    return "$normalized B"
  }
  val kilobyteTenths = ((normalized * 10.0) / 1024.0).roundToLong()
  if (kilobyteTenths < 10_240L) {
    return formatTenths(kilobyteTenths, "KB")
  }
  val megabyteTenths = ((normalized * 10.0) / (1024.0 * 1024.0)).roundToLong()
  return formatTenths(megabyteTenths, "MB")
}

private fun formatNativeNetworkClock(timestampMillis: Long): String {
  return formatNativeLogClock(timestampMillis)
}

private fun ResponseBody?.contentLengthOrNull(): Long? {
  val body = this ?: return null
  return runCatching { body.contentLength() }.getOrDefault(-1L).takeIf { it >= 0L }
}

private fun RequestBody.contentLengthOrNull(): Long? {
  return runCatching { contentLength() }.getOrDefault(-1L).takeIf { it >= 0L }
}

private fun shouldCaptureBodyPreview(contentType: String?, declaredLength: Long?): Boolean {
  if (declaredLength == 0L) {
    return false
  }
  return !isLikelyBinaryContentType(contentType?.lowercase(Locale.ROOT).orEmpty())
}

private fun ByteArray.isProbablyUtf8(): Boolean {
  val limit = minOf(size, 64)
  var index = 0
  var inspectedCodePoints = 0

  while (index < limit && inspectedCodePoints < 16) {
    val firstByte = this[index].toInt() and 0xFF
    val codePoint: Int
    val byteCount: Int

    when {
      firstByte and 0x80 == 0 -> {
        codePoint = firstByte
        byteCount = 1
      }
      firstByte and 0xE0 == 0xC0 -> {
        byteCount = 2
        if (index + byteCount > limit) {
          return true
        }
        val secondByte = this[index + 1].toInt() and 0xFF
        if (secondByte and 0xC0 != 0x80) {
          return false
        }
        codePoint = ((firstByte and 0x1F) shl 6) or (secondByte and 0x3F)
        if (codePoint < 0x80) {
          return false
        }
      }
      firstByte and 0xF0 == 0xE0 -> {
        byteCount = 3
        if (index + byteCount > limit) {
          return true
        }
        val secondByte = this[index + 1].toInt() and 0xFF
        val thirdByte = this[index + 2].toInt() and 0xFF
        if (secondByte and 0xC0 != 0x80 || thirdByte and 0xC0 != 0x80) {
          return false
        }
        codePoint =
          ((firstByte and 0x0F) shl 12) or
            ((secondByte and 0x3F) shl 6) or
            (thirdByte and 0x3F)
        if (codePoint < 0x800) {
          return false
        }
      }
      firstByte and 0xF8 == 0xF0 -> {
        byteCount = 4
        if (index + byteCount > limit) {
          return true
        }
        val secondByte = this[index + 1].toInt() and 0xFF
        val thirdByte = this[index + 2].toInt() and 0xFF
        val fourthByte = this[index + 3].toInt() and 0xFF
        if (
          secondByte and 0xC0 != 0x80 ||
            thirdByte and 0xC0 != 0x80 ||
            fourthByte and 0xC0 != 0x80
        ) {
          return false
        }
        codePoint =
          ((firstByte and 0x07) shl 18) or
            ((secondByte and 0x3F) shl 12) or
            ((thirdByte and 0x3F) shl 6) or
            (fourthByte and 0x3F)
        if (codePoint !in 0x10000..0x10FFFF) {
          return false
        }
      }
      else -> return false
    }

    if (Character.isISOControl(codePoint) && !Character.isWhitespace(codePoint)) {
      return false
    }

    index += byteCount
    inspectedCodePoints += 1
  }

  return true
}

private fun formatTenths(valueTenths: Long, unit: String): String {
  val whole = valueTenths / 10
  val fraction = valueTenths % 10
  return "$whole.$fraction $unit"
}

private fun formatProxyTypes(proxies: List<Proxy>): String {
  if (proxies.isEmpty()) {
    return "none"
  }

  return buildString(proxies.size * 8) {
    proxies.forEachIndexed { index, proxy ->
      if (index > 0) {
        append(", ")
      }
      append(proxy.type().name)
    }
  }
}
