// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Alexandru <https://alexandru.rocks> and the OpenCfMoto contributors.
// Part of OpenCfMoto. Free software under the GNU AGPL v3 or later; see LICENSE and NOTICE.
package dev.zanderp.opencfmoto

import android.content.Context

/** Process-wide holder for the opt-in BLE dash-clock link. */
object DashClockBle {
    @Volatile private var link: EcBtpTimeLink? = null

    fun start(context: Context, log: (String) -> Unit = LogBus::log) {
        stop()
        if (!AppSettings.bluetoothClockSync(context)) return
        val next = EcBtpTimeLink(context, log)
        link = next
        runCatching { next.start() }
            .onFailure {
                log("[EC-BTP] start failed: $it")
                stop()
            }
    }

    fun stop() {
        link?.let { runCatching { it.close() } }
        link = null
    }
}
