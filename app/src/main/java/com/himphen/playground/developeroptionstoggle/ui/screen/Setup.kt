package com.himphen.playground.developeroptionstoggle.ui.screen

import android.Manifest
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.core.app.NotificationManagerCompat
import androidx.core.graphics.drawable.toBitmap
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import com.himphen.playground.developeroptionstoggle.R
import com.himphen.playground.developeroptionstoggle.remote.MutedApps
import com.himphen.playground.developeroptionstoggle.remote.NotifListener
import com.himphen.playground.developeroptionstoggle.remote.SmsSender
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private class SetupItem(val title: String, val purpose: String, val done: Boolean, val open: () -> Unit)

private fun granted(context: Context, vararg permissions: String) =
    permissions.all { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

// Each continuity feature needs one grant or special access; every row opens the exact screen or prompt for it.
@Composable
fun SetupSection() {
    val context = LocalContext.current
    var refresh by remember { mutableIntStateOf(0) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { refresh++ }
    val request = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        SmsSender.refreshSims(context); refresh++
    }
    fun open(intent: Intent) = try { context.startActivity(intent) } catch (_: ActivityNotFoundException) {
        context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")))
    }
    val pkg = context.packageName
    val items = remember(refresh) {
        val listener = ComponentName(context, NotifListener::class.java)
        listOfNotNull(
            SetupItem("Notification access", "OTP codes and notifications on your Mac",
                pkg in NotificationManagerCompat.getEnabledListenerPackages(context)) {
                open(if (Build.VERSION.SDK_INT >= 30) Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
                    .putExtra(Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME, listener.flattenToString())
                    else Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
            },
            SetupItem("SMS", "Codes from SMS, and texting from your Mac",
                granted(context, Manifest.permission.RECEIVE_SMS, Manifest.permission.SEND_SMS)) {
                request.launch(arrayOf(Manifest.permission.RECEIVE_SMS, Manifest.permission.SEND_SMS))
            },
            SetupItem("Phone", "Incoming calls on your Mac, Decline, and SIM choice",
                granted(context, Manifest.permission.READ_PHONE_STATE, Manifest.permission.READ_CALL_LOG, Manifest.permission.ANSWER_PHONE_CALLS)) {
                request.launch(arrayOf(Manifest.permission.READ_PHONE_STATE, Manifest.permission.READ_CALL_LOG, Manifest.permission.ANSWER_PHONE_CALLS))
            },
            SetupItem("Contacts", "Caller names", granted(context, Manifest.permission.READ_CONTACTS)) {
                request.launch(arrayOf(Manifest.permission.READ_CONTACTS))
            },
            if (Build.VERSION.SDK_INT >= 33) SetupItem("Notifications", "Find My Phone and received files",
                granted(context, Manifest.permission.POST_NOTIFICATIONS)) {
                request.launch(arrayOf(Manifest.permission.POST_NOTIFICATIONS))
            } else null,
            SetupItem("Do Not Disturb access", "Find My Phone rings through Do Not Disturb",
                context.getSystemService(NotificationManager::class.java).isNotificationPolicyAccessGranted) {
                open(Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS))
            },
            SetupItem("Unrestricted battery", "Keeps the Mac link alive while the phone sleeps",
                context.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(pkg)) {
                @Suppress("BatteryLife")
                open(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$pkg")))
            },
            if (Build.VERSION.SDK_INT >= 37) SetupItem("Local network", "Reach your Mac on this Wi-Fi",
                granted(context, "android.permission.ACCESS_LOCAL_NETWORK")) {
                request.launch(arrayOf("android.permission.ACCESS_LOCAL_NETWORK"))
            } else null,
        )
    }
    Column {
        SectionHeader("Set up Mac features")
        GroupCard {
            items.forEachIndexed { index, item ->
                if (index > 0) HorizontalDivider(Modifier.padding(start = 56.dp, end = 16.dp), color = MaterialTheme.colorScheme.outlineVariant)
                ListItem(
                    headlineContent = { Text(item.title) },
                    supportingContent = { Text(if (item.done) item.purpose else "Not allowed. ${item.purpose}") },
                    leadingContent = {
                        Icon(painterResource(if (item.done) R.drawable.ic_check_circle else R.drawable.ic_warning), contentDescription = null,
                            tint = if (item.done) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error)
                    },
                    trailingContent = { if (!item.done) TextButton(onClick = item.open) { Text("Allow") } },
                    colors = ListItemDefaults.colors(containerColor = Color.Transparent)
                )
            }
        }
        // Android 13+ greys out notification access for sideloaded apps until restricted settings are allowed.
        if (!items.first().done) RestrictedSettingsHint(pkg)
    }
}

@Composable
private fun RestrictedSettingsHint(pkg: String) {
    val context = LocalContext.current
    val command = "adb shell cmd notification allow_listener $pkg/.remote.NotifListener"
    Surface(Modifier.fillMaxWidth().padding(top = 12.dp), shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.surfaceContainer) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Switch greyed out?", style = MaterialTheme.typography.titleSmall)
            Text("Open App info, tap ⋮, then Allow restricted settings. Or run this from your Mac:",
                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Surface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(12.dp), color = MaterialTheme.colorScheme.surface) {
                Text(command, Modifier.padding(12.dp), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = {
                    context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$pkg")))
                }) { Text("App info") }
                TextButton(onClick = {
                    context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("adb command", command))
                }) { Text("Copy command") }
            }
        }
    }
}

private class AppRow(val pkg: String, val label: String, val icon: ImageBitmap?)

// Apps whose notifications are mirrored to the Mac; switching one off adds it to MutedApps.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MutedAppsScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    BackHandler(onBack = onBack)
    val apps by produceState<List<AppRow>?>(null) {
        value = withContext(Dispatchers.IO) {
            val pm = context.packageManager
            pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0)
                .map { it.activityInfo.applicationInfo }.distinctBy { it.packageName }.filter { it.packageName != context.packageName }
                .map { AppRow(it.packageName, pm.getApplicationLabel(it).toString(),
                    runCatching { pm.getApplicationIcon(it).toBitmap(96, 96).asImageBitmap() }.getOrNull()) }
                .sortedBy { it.label.lowercase() }
        }
    }
    var muted by remember { mutableStateOf(MutedApps.all(context)) }
    Scaffold(containerColor = MaterialTheme.colorScheme.surface, topBar = {
        TopAppBar(title = { Text("Notifications on your Mac") },
            navigationIcon = { IconButton(onClick = onBack) { Icon(painterResource(R.drawable.ic_arrow_back), contentDescription = "Back") } },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.surface))
    }) { inset ->
        val list = apps
        if (list == null) {
            Box(Modifier.fillMaxSize().padding(inset)) { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            return@Scaffold
        }
        LazyColumn(Modifier.fillMaxSize().padding(inset)) {
            item {
                Text("Turn an app off to stop showing its notifications on your Mac.", Modifier.padding(16.dp),
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            items(list, key = { it.pkg }) { app ->
                val on = app.pkg !in muted
                ListItem(
                    headlineContent = { Text(app.label) },
                    leadingContent = { app.icon?.let { Image(it, contentDescription = null, Modifier.size(40.dp)) } ?: Spacer(Modifier.size(40.dp)) },
                    trailingContent = { Switch(checked = on, onCheckedChange = { MutedApps.set(context, app.pkg, !it); muted = MutedApps.all(context) }) },
                    colors = ListItemDefaults.colors(containerColor = Color.Transparent)
                )
            }
        }
    }
}
