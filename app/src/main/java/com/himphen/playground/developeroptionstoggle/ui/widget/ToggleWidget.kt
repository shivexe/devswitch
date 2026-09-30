package com.himphen.playground.developeroptionstoggle.ui.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.graphics.Color
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.LocalContext
import androidx.glance.LocalGlanceId
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.state.updateAppWidgetState
import androidx.glance.background
import androidx.glance.currentState
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.fillMaxSize
import androidx.glance.state.PreferencesGlanceStateDefinition
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.himphen.playground.developeroptionstoggle.R
import com.himphen.playground.developeroptionstoggle.data.DeveloperSettingManager
import com.himphen.playground.developeroptionstoggle.data.SettingReadResult
import com.himphen.playground.developeroptionstoggle.data.SettingTarget
import com.himphen.playground.developeroptionstoggle.data.SettingWriteResult
import kotlinx.coroutines.launch

class ToggleWidget : GlanceAppWidget() {

    override var stateDefinition = PreferencesGlanceStateDefinition

    companion object {
        private val devOptionsEnabledKey = booleanPreferencesKey("dev_options_enabled")
        private val widgetErrorKey = booleanPreferencesKey("widget_error")
    }

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val manager = DeveloperSettingManager(context.contentResolver)
        val readResult = manager.read(SettingTarget.DEVELOPER_OPTIONS)
        updateAppWidgetState(context, id) { preferences ->
            when (readResult) {
                is SettingReadResult.Success -> {
                    preferences[devOptionsEnabledKey] = readResult.enabled
                    preferences[widgetErrorKey] = false
                }

                is SettingReadResult.Failure -> {
                    preferences[widgetErrorKey] = true
                }
            }
        }
        provideContent {
            Content()
        }
    }

    @Composable
    private fun Content() {
        val context = LocalContext.current
        val glanceId = LocalGlanceId.current
        val isEnabled = currentState(key = devOptionsEnabledKey) ?: false
        val hasError = currentState(key = widgetErrorKey) ?: false
        val coroutineScope = rememberCoroutineScope()
        val backgroundColor = when {
            hasError -> Color(0xFF5D1A1D)
            isEnabled -> Color(0xFF1D496F)
            else -> Color(0xFF202B36)
        }

        Box(
            modifier = GlanceModifier
                .fillMaxSize()
                .background(backgroundColor)
                .clickable {
                    coroutineScope.launch {
                        val manager = DeveloperSettingManager(context.contentResolver)
                        val readResult = manager.read(SettingTarget.DEVELOPER_OPTIONS)

                        updateAppWidgetState(context, glanceId) { preferences ->
                            when (readResult) {
                                is SettingReadResult.Success -> {
                                    val newStatus = !readResult.enabled
                                    when (
                                        manager.write(
                                            SettingTarget.DEVELOPER_OPTIONS,
                                            newStatus
                                        )
                                    ) {
                                        SettingWriteResult.Success -> {
                                            preferences[devOptionsEnabledKey] = newStatus
                                            preferences[widgetErrorKey] = false
                                        }

                                        is SettingWriteResult.Failure -> {
                                            preferences[widgetErrorKey] = true
                                        }
                                    }
                                }

                                is SettingReadResult.Failure -> {
                                    preferences[widgetErrorKey] = true
                                }
                            }
                        }
                        update(context, glanceId)
                    }
                },
            contentAlignment = Alignment.Center
        ) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Text(
                    text = context.getString(R.string.widget_toggle_label),
                    style = TextStyle(
                        color = ColorProvider(Color.White),
                        fontWeight = FontWeight.Medium
                    )
                )
                Text(
                    text = when {
                        hasError -> context.getString(R.string.widget_unavailable)
                        isEnabled -> context.getString(R.string.widget_on)
                        else -> context.getString(R.string.widget_off)
                    },
                    style = TextStyle(
                        color = ColorProvider(Color.White),
                        fontWeight = FontWeight.Bold
                    )
                )
            }
        }
    }
}
