package com.tapnab.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Handles the buttons on the casting notification. */
class CastActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            CastService.ACTION_PREV -> DlnaCaster.control("previous")
            CastService.ACTION_NEXT -> DlnaCaster.control("next")
            CastService.ACTION_STOP -> DlnaCaster.control("stop")
            CastService.ACTION_TOGGLE -> {
                val paused = DlnaCaster.state()["status"] == "paused"
                DlnaCaster.control(if (paused) "resume" else "pause")
            }
        }
    }
}
