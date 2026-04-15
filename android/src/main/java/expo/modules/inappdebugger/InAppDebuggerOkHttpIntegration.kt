package expo.modules.inappdebugger

import okhttp3.OkHttpClient

object InAppDebuggerOkHttpIntegration {
  // One-time builder/client wiring for app-owned native OkHttp stacks.
  @JvmStatic
  fun instrument(builder: OkHttpClient.Builder): OkHttpClient.Builder {
    return InAppDebuggerNativeNetworkCapture.applyTo(builder)
  }

  @JvmStatic
  fun instrument(client: OkHttpClient): OkHttpClient {
    return instrument(client.newBuilder()).build()
  }

  @JvmStatic
  fun newBuilder(): OkHttpClient.Builder {
    return instrument(OkHttpClient.Builder())
  }
}
