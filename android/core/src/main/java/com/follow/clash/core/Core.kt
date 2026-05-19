package com.follow.clash.core

import android.content.Context
import java.io.File
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.URL

data object Core {
    private var loaded = false

    fun load(context: Context) {
        if (loaded) return
        val override = File(context.filesDir, "core_override/libclash.so")
        var loadedOverride = false
        try {
            if (override.exists()) {
                System.load(override.absolutePath)
                loadedOverride = true
            }
            System.loadLibrary("core")
        } catch (e: Throwable) {
            if (override.exists()) {
                override.delete()
            }
            if (!loadedOverride) {
                System.loadLibrary("core")
            } else {
                throw e
            }
        }
        loaded = true
    }

    private external fun startTun(
        fd: Int,
        cb: TunInterface,
        stack: String,
        address: String,
        dns: String,
    )

    external fun forceGC(
    )

    external fun updateDNS(
        dns: String,
    )

    private fun parseInetSocketAddress(address: String): InetSocketAddress {
        val url = URL("https://$address")

        return InetSocketAddress(InetAddress.getByName(url.host), url.port)
    }

    fun startTun(
        fd: Int,
        protect: (Int) -> Boolean,
        resolverProcess: (protocol: Int, source: InetSocketAddress, target: InetSocketAddress, uid: Int) -> String,
        stack: String,
        address: String,
        dns: String,
    ) {
        startTun(
            fd,
            object : TunInterface {
                override fun protect(fd: Int) {
                    protect(fd)
                }

                override fun resolverProcess(
                    protocol: Int,
                    source: String,
                    target: String,
                    uid: Int
                ): String {
                    return resolverProcess(
                        protocol,
                        parseInetSocketAddress(source),
                        parseInetSocketAddress(target),
                        uid,
                    )
                }
            },
            stack,
            address,
            dns
        )
    }

    external fun suspended(
        suspended: Boolean,
    )

    private external fun invokeAction(
        data: String,
        cb: InvokeInterface
    )

    fun invokeAction(
        data: String,
        cb: (result: String?) -> Unit
    ) {
        invokeAction(
            data,
            object : InvokeInterface {
                override fun onResult(result: String?) {
                    cb(result)
                }
            },
        )
    }

    private external fun setEventListener(cb: InvokeInterface?)

    fun callSetEventListener(
        cb: ((result: String?) -> Unit)?
    ) {
        when (cb != null) {
            true -> setEventListener(
                object : InvokeInterface {
                    override fun onResult(result: String?) {
                        cb(result)
                    }
                },
            )

            false -> setEventListener(null)
        }
    }

    fun quickSetup(
        initParamsString: String,
        setupParamsString: String,
        cb: (result: String?) -> Unit,
    ) {
        quickSetup(
            initParamsString,
            setupParamsString,
            object : InvokeInterface {
                override fun onResult(result: String?) {
                    cb(result)
                }
            },
        )
    }

    private external fun quickSetup(
        initParamsString: String,
        setupParamsString: String,
        cb: InvokeInterface
    )

    external fun stopTun()

    external fun getTraffic(onlyStatisticsProxy: Boolean): String

    external fun getTotalTraffic(onlyStatisticsProxy: Boolean): String

    init {}
}
