package com.himphen.playground.developeroptionstoggle.ui.widget

import android.content.Intent
import android.provider.Settings
import androidx.compose.runtime.Composable
import androidx.glance.GlanceModifier
import androidx.glance.LocalContext
import androidx.glance.action.clickable
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.fillMaxSize
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.himphen.playground.developeroptionstoggle.R

class ShortcutWidget : GlanceAppWidget() {

    override suspend fun provideGlance(
        context: android.content.Context,
        id: androidx.glance.GlanceId
    ) {
        provideContent {
            Content()
        }
    }

    @Composable
    private fun Content() {
        val context = LocalContext.current
        Box(
            modifier = GlanceModifier
                .fillMaxSize()
                .background(androidx.compose.ui.graphics.Color(0xFF202B36))
                .clickable(
                    actionStartActivity(
                        Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
                    )
                ),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = context.getString(R.string.widget_shortcut_label),
                style = TextStyle(
                    color = ColorProvider(androidx.compose.ui.graphics.Color.White),
                    fontWeight = FontWeight.Bold
                )
            )
        }
    }
}
