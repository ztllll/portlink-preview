package dev.portlink.portlink

import android.content.Context
import dev.portlink.app.SessionRuntime
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/** The Activity renders the one application-owned engine; it never owns SSH. */
class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine =
        SessionRuntime.engineForActivity(context)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        // Preserve Flutter/ActivityAware plugin callbacks as well as our runtime.
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        SessionRuntime.onRequestPermissionsResult(requestCode)
    }
}
