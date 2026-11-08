package com.himphen.playground.developeroptionstoggle.ui.screen

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import android.text.format.DateUtils
import android.text.format.Formatter
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.himphen.playground.developeroptionstoggle.R
import com.himphen.playground.developeroptionstoggle.remote.PairStore
import com.himphen.playground.developeroptionstoggle.remote.PairingActivity
import com.himphen.playground.developeroptionstoggle.remote.Received
import com.himphen.playground.developeroptionstoggle.remote.RemoteService
import com.himphen.playground.developeroptionstoggle.ui.viewmodel.MainUiError
import com.himphen.playground.developeroptionstoggle.ui.viewmodel.MainViewModel
import kotlinx.coroutines.delay

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(viewModel: MainViewModel) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val lifecycleOwner = androidx.lifecycle.compose.LocalLifecycleOwner.current
    var connection by remember { mutableStateOf(RemoteService.connectionState) }
    val loadMacName = { try { PairStore.load(context)?.getString("desktopName") } catch (_: Exception) { null } }
    var macName by remember { mutableStateOf(loadMacName()) }
    LaunchedEffect(Unit) { while (true) { connection = RemoteService.connectionState; delay(1000) } }
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) { viewModel.refreshStatus(); macName = loadMacName() }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    val openDeveloperSettings = {
        try { context.startActivity(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)) }
        catch (_: ActivityNotFoundException) { viewModel.showSystemSettingsError() }
        catch (_: SecurityException) { viewModel.showSystemSettingsError() }
    }
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    Scaffold(
        modifier = Modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        containerColor = MaterialTheme.colorScheme.surface,
        topBar = {
            LargeTopAppBar(title = { Text(stringResource(R.string.app_name)) }, scrollBehavior = scrollBehavior,
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.surface,
                    scrolledContainerColor = MaterialTheme.colorScheme.surfaceContainer))
        }
    ) { inset ->
        if (uiState.isLoading) {
            Box(Modifier.fillMaxSize().padding(inset), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            return@Scaffold
        }
        val isUpdating = uiState.updatingSetting != null
        val canChange = uiState.hasPermission && !isUpdating
        Box(Modifier.fillMaxSize().padding(inset), contentAlignment = Alignment.TopCenter) {
            Column(Modifier.widthIn(max = 600.dp).fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 24.dp),
                verticalArrangement = Arrangement.spacedBy(24.dp)) {
                MacCard(macName, connection) { context.startActivity(Intent(context, PairingActivity::class.java)) }
                DeveloperCard(uiState.developerOptionsEnabled, canChange, viewModel::setDeveloperOptions)
                if (!uiState.hasPermission) PermissionCard()
                uiState.error?.let { error ->
                    if (error !is MainUiError.PermissionRequired) ErrorCard(error, if (error is MainUiError.SystemSettingsUnavailable) openDeveloperSettings else { { viewModel.refreshStatus() } })
                }
                if (macName != null) FromMacSection()
                Column {
                    SectionHeader("Debugging")
                    GroupCard {
                        val enabled = canChange && uiState.developerOptionsEnabled
                        val hint = if (uiState.developerOptionsEnabled) null else "Turn on Development first"
                        // Control Phone on the Mac needs this; call it out when it is the missing piece.
                        val wirelessNeeded = uiState.developerOptionsEnabled && !uiState.wifiDebuggingEnabled
                        SwitchRow(R.drawable.ic_wifi, "Wireless debugging",
                            hint ?: if (wirelessNeeded) "Off. Your Mac needs this for Control Phone." else "On. Your Mac can use Control Phone.",
                            uiState.wifiDebuggingEnabled, enabled, viewModel::setWifiDebugging, emphasize = wirelessNeeded)
                        HorizontalDivider(Modifier.padding(start = 56.dp, end = 16.dp), color = MaterialTheme.colorScheme.outlineVariant)
                        SwitchRow(R.drawable.ic_usb, "USB debugging", hint ?: "Connect with a USB cable",
                            uiState.usbDebuggingEnabled, enabled, viewModel::setUsbDebugging)
                    }
                }
                if (macName != null) SetupSection()
                Column {
                    SectionHeader("More")
                    GroupCard {
                        NavRow(R.drawable.ic_code, "Android developer options", "Every setting, in system Settings",
                            trailing = R.drawable.ic_open_in_new, onClick = openDeveloperSettings)
                    }
                }
                Text("Works on your local network. No account needed.", Modifier.align(Alignment.CenterHorizontally),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun MacCard(macName: String?, connection: String, onClick: () -> Unit) {
    val connected = isConnected(connection)
    Surface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.surfaceContainer) {
        Row(Modifier.clickable(onClick = onClick).padding(20.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            IconBadge(R.drawable.ic_laptop, size = 48.dp,
                container = if (connected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.secondaryContainer,
                content = if (connected) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSecondaryContainer)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(macName ?: "Pair with your Mac", style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (macName == null) {
                    Text("Control this phone from your Mac's menu bar", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                } else {
                    Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        StatusDot(connected, Modifier.padding(top = 6.dp))
                        Text(if (connected) "Connected" else connection, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
            Icon(painterResource(R.drawable.ic_chevron_right), contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

// Files the Mac sent, newest first; refreshed whenever MediaStore Downloads changes.
@Composable
private fun FromMacSection() {
    val context = LocalContext.current
    var files by remember { mutableStateOf(emptyList<Received.Item>()) }
    DisposableEffect(Unit) {
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) { files = Received.recent(context) }
        }
        observer.onChange(false)
        context.contentResolver.registerContentObserver(MediaStore.Downloads.EXTERNAL_CONTENT_URI, true, observer)
        onDispose { context.contentResolver.unregisterContentObserver(observer) }
    }
    Column {
        SectionHeader("From your Mac")
        GroupCard {
            if (files.isEmpty()) {
                ListItem(headlineContent = { Text("No files yet") },
                    supportingContent = { Text("Use Send File or drop a file on the DevSwitch menu on your Mac.") },
                    leadingContent = { Icon(painterResource(R.drawable.ic_file), contentDescription = null) },
                    colors = ListItemDefaults.colors(containerColor = Color.Transparent))
            }
            files.forEach { file ->
                val at = file.addedSeconds * 1000
                val ago = if (System.currentTimeMillis() - at < DateUtils.MINUTE_IN_MILLIS) "Just now"
                    else DateUtils.getRelativeTimeSpanString(at, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS)
                NavRow(R.drawable.ic_file, file.name, "${Formatter.formatShortFileSize(context, file.size)} · $ago",
                    trailing = R.drawable.ic_open_in_new) { Received.open(context, file.uri, file.mime, file.name) }
                HorizontalDivider(Modifier.padding(start = 56.dp, end = 16.dp), color = MaterialTheme.colorScheme.outlineVariant)
            }
            if (files.isNotEmpty()) TextButton(onClick = { Received.showAll(context) }, Modifier.padding(start = 8.dp)) { Text("Show all in Downloads › DevSwitch") }
        }
        Text("To send to your Mac: the “Send clipboard to Mac” Quick Settings tile, or Share › Send to Mac.",
            Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp), style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun DeveloperCard(enabled: Boolean, canChange: Boolean, onChange: (Boolean) -> Unit) {
    val container = if (enabled) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceContainerHigh
    val content = if (enabled) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onSurface
    Surface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(24.dp), color = container, contentColor = content) {
        Row(Modifier.toggleable(value = enabled, enabled = canChange, role = Role.Switch, onValueChange = onChange).padding(24.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("Development", style = MaterialTheme.typography.titleLarge)
                Text(if (enabled) "On. Developer options are enabled on this phone." else "Off. Turn on to use debugging and Control Phone.",
                    style = MaterialTheme.typography.bodyMedium, color = content.copy(alpha = 0.8f))
            }
            Switch(checked = enabled, onCheckedChange = null, enabled = canChange)
        }
    }
}

@Composable
private fun PermissionCard() {
    val context = LocalContext.current
    val command = stringResource(R.string.permission_command)
    ProblemCard(stringResource(R.string.permission_title), stringResource(R.string.permission_message), actions = {
        TextButton(onClick = {
            context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("adb command", command))
        }, colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.onErrorContainer)) {
            Icon(painterResource(R.drawable.ic_copy), contentDescription = null, Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text("Copy command")
        }
    }) {
        Surface(Modifier.fillMaxWidth().padding(top = 4.dp), shape = RoundedCornerShape(12.dp),
            color = MaterialTheme.colorScheme.surface.copy(alpha = 0.5f)) {
            Text(command, Modifier.padding(12.dp), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable
private fun ErrorCard(error: MainUiError, onRetry: () -> Unit) {
    val message = when (error) {
        is MainUiError.ReadFailed -> stringResource(R.string.error_read_settings)
        is MainUiError.WriteFailed -> stringResource(R.string.error_write_settings)
        MainUiError.SystemSettingsUnavailable -> stringResource(R.string.error_system_settings_unavailable)
        MainUiError.PermissionRequired -> stringResource(R.string.error_permission_required)
    }
    ProblemCard(stringResource(R.string.error_title), message, actions = {
        Button(onClick = onRetry, colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error,
            contentColor = MaterialTheme.colorScheme.onError)) { Text(stringResource(R.string.retry)) }
    })
}
