package com.himphen.playground.developeroptionstoggle.ui.screen

import android.content.ActivityNotFoundException
import android.content.Intent
import android.provider.Settings
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.himphen.playground.developeroptionstoggle.R
import com.himphen.playground.developeroptionstoggle.remote.PairingActivity
import com.himphen.playground.developeroptionstoggle.remote.RemoteService
import com.himphen.playground.developeroptionstoggle.ui.viewmodel.MainUiError
import com.himphen.playground.developeroptionstoggle.ui.viewmodel.MainViewModel
import kotlinx.coroutines.delay

@Composable
fun DeviceMark(laptop: Boolean = false, modifier: Modifier = Modifier) {
    val color = MaterialTheme.colorScheme.primary
    Canvas(modifier.size(28.dp)) {
        scale(size.width / 24f, size.height / 24f, pivot = Offset.Zero) {
            if (laptop) {
                drawRoundRect(color, Offset(3f, 4f), Size(18f, 13f), androidx.compose.ui.geometry.CornerRadius(2f), style = Stroke(1.6f))
                drawLine(color, Offset(1f, 20f), Offset(23f, 20f), 1.6f)
            } else {
                drawRoundRect(color, Offset(5f, 1f), Size(14f, 22f), androidx.compose.ui.geometry.CornerRadius(3f), style = Stroke(1.6f))
                drawLine(color, Offset(10f, 19f), Offset(14f, 19f), 1.6f)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(viewModel: MainViewModel) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val lifecycleOwner = androidx.lifecycle.compose.LocalLifecycleOwner.current
    var connection by remember { mutableStateOf(RemoteService.connectionState) }
    LaunchedEffect(Unit) { while (true) { connection = RemoteService.connectionState; delay(1000) } }
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) viewModel.refreshStatus() }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    val openDeveloperSettings = {
        try { context.startActivity(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)) }
        catch (_: ActivityNotFoundException) { viewModel.showSystemSettingsError() }
        catch (_: SecurityException) { viewModel.showSystemSettingsError() }
    }
    Scaffold(containerColor = MaterialTheme.colorScheme.background) { inset ->
        if (uiState.isLoading) {
            Box(Modifier.fillMaxSize().padding(inset), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        } else {
            Box(Modifier.fillMaxSize().padding(inset), contentAlignment = Alignment.TopCenter) {
                Column(Modifier.widthIn(max = 600.dp).fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
                    verticalArrangement = Arrangement.spacedBy(24.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Box(Modifier.size(48.dp).background(MaterialTheme.colorScheme.primaryContainer, RoundedCornerShape(14.dp)), contentAlignment = Alignment.Center) { DeviceMark() }
                        Column {
                            Text("DevSwitch", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                            Text("Your phone. Your control.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    val isUpdating = uiState.updatingSetting != null
                    Surface(shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.primaryContainer) {
                        Column(Modifier.fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            Text("DEVELOPER OPTIONS", style = MaterialTheme.typography.labelMedium, letterSpacing = 1.5.sp, color = MaterialTheme.colorScheme.onPrimaryContainer)
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(if (uiState.developerOptionsEnabled) "Enabled" else "Disabled", Modifier.weight(1f), style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onPrimaryContainer)
                                Switch(checked = uiState.developerOptionsEnabled, onCheckedChange = viewModel::setDeveloperOptions,
                                    enabled = uiState.hasPermission && !isUpdating,
                                    modifier = Modifier.semantics { contentDescription = "Developer options" })
                            }
                            Text(if (uiState.developerOptionsEnabled) "Choose how your Mac connects below." else "Turn on to use debugging and screen control.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onPrimaryContainer)
                        }
                    }
                    if (!uiState.hasPermission) PermissionWarning()
                    uiState.error?.let { error ->
                        if (error !is MainUiError.PermissionRequired) ErrorCard(error, if (error is MainUiError.SystemSettingsUnavailable) openDeveloperSettings else { { viewModel.refreshStatus() } })
                    }
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        SectionLabel("CONNECTIONS")
                        Surface(shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.surface) {
                            Column {
                                SettingRow("Wireless debugging", "Screen control over Wi-Fi", uiState.wifiDebuggingEnabled, uiState.hasPermission && uiState.developerOptionsEnabled && !isUpdating, viewModel::setWifiDebugging)
                                HorizontalDivider(Modifier.padding(horizontal = 20.dp), color = MaterialTheme.colorScheme.outlineVariant)
                                SettingRow("USB debugging", "Connect with a USB cable", uiState.usbDebuggingEnabled, uiState.hasPermission && uiState.developerOptionsEnabled && !isUpdating, viewModel::setUsbDebugging)
                            }
                        }
                        if (!uiState.developerOptionsEnabled) Text("Enable Developer options to change these settings.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        SectionLabel("YOUR MAC")
                        Card(onClick = { context.startActivity(Intent(context, PairingActivity::class.java)) },
                            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface), shape = RoundedCornerShape(20.dp)) {
                            Row(Modifier.fillMaxWidth().padding(20.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                                DeviceMark(laptop = true)
                                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                    Text("Mac connection", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                                    Text(connection, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                                Text("→", style = MaterialTheme.typography.titleLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                    TextButton(onClick = openDeveloperSettings, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text("Open Android developer settings") }
                    Text("Managed locally. No cloud account needed.", Modifier.align(Alignment.CenterHorizontally), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}

@Composable
fun SectionLabel(text: String) {
    Text(text, style = MaterialTheme.typography.labelMedium, letterSpacing = 1.5.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun SettingRow(title: String, description: String, checked: Boolean, enabled: Boolean, onCheckedChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().toggleable(value = checked, enabled = enabled, role = Role.Switch, onValueChange = onCheckedChange).padding(20.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurface)
            Text(description, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Switch(checked = checked, onCheckedChange = null, enabled = enabled)
    }
}

@Composable
private fun PermissionWarning() {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.errorContainer
        )
    ) {
        Column(modifier = Modifier.padding(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = contextString(R.string.permission_title),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onErrorContainer
                )
            }
            Spacer(modifier = Modifier.height(10.dp))
            Text(
                text = contextString(R.string.permission_message),
                color = MaterialTheme.colorScheme.onErrorContainer
            )
            Spacer(modifier = Modifier.height(10.dp))
            Surface(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp),
                color = MaterialTheme.colorScheme.surface.copy(alpha = 0.25f)
            ) {
                Text(
                    text = contextString(R.string.permission_command),
                    modifier = Modifier.padding(12.dp),
                    fontFamily = FontFamily.Monospace,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onErrorContainer
                )
            }
        }
    }
}

@Composable
private fun ErrorCard(
    error: MainUiError,
    onRetry: () -> Unit
) {
    val message = when (error) {
        is MainUiError.ReadFailed -> contextString(R.string.error_read_settings)
        is MainUiError.WriteFailed -> contextString(R.string.error_write_settings)
        MainUiError.SystemSettingsUnavailable ->
            contextString(R.string.error_system_settings_unavailable)

        MainUiError.PermissionRequired -> contextString(R.string.error_permission_required)
    }

    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.tertiaryContainer
        )
    ) {
        Column(modifier = Modifier.padding(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = contextString(R.string.error_title),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onTertiaryContainer
                )
            }
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = message,
                color = MaterialTheme.colorScheme.onTertiaryContainer
            )
            Spacer(modifier = Modifier.height(10.dp))
            Button(onClick = onRetry) {
                Text(text = contextString(R.string.retry))
            }
        }
    }
}

@Composable
private fun contextString(resourceId: Int): String {
    return androidx.compose.ui.res.stringResource(resourceId)
}
