package dev.portlink.app

import android.app.Application

/** No engine, sockets, or service is started merely by creating the process. */
class PortLinkApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        SessionRuntime.initialize(this)
    }
}
