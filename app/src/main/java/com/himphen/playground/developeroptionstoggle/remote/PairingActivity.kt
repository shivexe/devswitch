package com.himphen.playground.developeroptionstoggle.remote

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.*
import android.provider.Settings
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.enableEdgeToEdge
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.zxing.BarcodeFormat
import com.journeyapps.barcodescanner.BarcodeCallback
import com.journeyapps.barcodescanner.BarcodeResult
import com.journeyapps.barcodescanner.BarcodeView
import com.journeyapps.barcodescanner.DefaultDecoderFactory
import com.himphen.playground.developeroptionstoggle.ui.theme.DeveloperOptionsToggleTheme
import com.himphen.playground.developeroptionstoggle.R
import com.himphen.playground.developeroptionstoggle.ui.screen.*
import kotlinx.coroutines.delay
import org.json.JSONObject
import java.util.UUID

class PairingActivity : ComponentActivity() {
    private var pairedName by mutableStateOf<String?>(null)
    private var scanning by mutableStateOf(false)
    private var waiting by mutableStateOf(false)
    private var comparisonCode by mutableStateOf("")
    private var errorText by mutableStateOf("")
    private var mutedAppsOpen by mutableStateOf(false)
    private var pairingThread: Thread? = null
    @Volatile private var cancelled = false
    private val notifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) { }
    private val camera = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) scanning = true else errorText = "Camera access is needed to scan. You can also paste a pairing invitation."
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        pairedName = try { PairStore.load(this)?.getString("desktopName") } catch (_: Exception) { null }
        setContent { DeveloperOptionsToggleTheme { if (mutedAppsOpen) MutedAppsScreen { mutedAppsOpen = false } else ConnectionScreen() } }
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            notifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }
    private fun scan() {
        errorText = ""
        if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) scanning = true
        else camera.launch(Manifest.permission.CAMERA)
    }
    @OptIn(ExperimentalMaterial3Api::class)
    @Composable
    private fun ConnectionScreen() {
        var connection by remember { mutableStateOf(RemoteService.connectionState) }
        var pasteOpen by remember { mutableStateOf(false) }
        var invitationText by remember { mutableStateOf("") }
        var unpairOpen by remember { mutableStateOf(false) }
        var paused by remember { mutableStateOf(getSharedPreferences("devswitch", MODE_PRIVATE).getBoolean("paused", false)) }
        LaunchedEffect(Unit) { while (true) { connection = RemoteService.connectionState; delay(1000) } }
        Scaffold(containerColor = MaterialTheme.colorScheme.surface, topBar = {
            TopAppBar(title = { Text("Mac connection") },
                navigationIcon = { IconButton(onClick = { finish() }) { Icon(painterResource(R.drawable.ic_arrow_back), contentDescription = "Back") } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.surface))
        }) { inset ->
            Column(Modifier.fillMaxSize().padding(inset).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(top = 8.dp, bottom = 24.dp),
                verticalArrangement = Arrangement.spacedBy(24.dp)) {
                when {
                    pairedName != null -> {
                        val connected = isConnected(connection)
                        Column(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            IconBadge(R.drawable.ic_laptop, size = 72.dp,
                                container = if (connected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.secondaryContainer,
                                content = if (connected) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSecondaryContainer)
                            Text(pairedName.orEmpty(), Modifier.padding(top = 8.dp), style = MaterialTheme.typography.headlineSmall, textAlign = TextAlign.Center)
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                StatusDot(connected)
                                Text(connection, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                        Surface(shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.surfaceContainer) {
                            Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                                Text(if (paused) "Mac control is paused" else "Mac control is on", style = MaterialTheme.typography.titleMedium)
                                Text(if (paused) "Resume to receive commands from your Mac." else "Use the Mac menu bar to control your phone or switch development on and off.",
                                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                if (paused) {
                                    Button(onClick = {
                                        getSharedPreferences("devswitch", MODE_PRIVATE).edit().putBoolean("paused", false).apply()
                                        paused = false
                                        RemoteService.start(this@PairingActivity)
                                    }, modifier = Modifier.fillMaxWidth().padding(top = 4.dp)) { Text("Resume Mac control") }
                                } else {
                                    OutlinedButton(onClick = {
                                        getSharedPreferences("devswitch", MODE_PRIVATE).edit().putBoolean("paused", true).apply()
                                        paused = true
                                        stopService(Intent(this@PairingActivity, RemoteService::class.java))
                                    }, modifier = Modifier.fillMaxWidth().padding(top = 4.dp)) { Text("Pause Mac control") }
                                }
                            }
                        }
                        Column {
                            SectionHeader("Stay connected")
                            GroupCard {
                                NavRow(R.drawable.ic_laptop, "Notifications on your Mac", "Choose which apps show up") { mutedAppsOpen = true }
                                HorizontalDivider(Modifier.padding(start = 56.dp, end = 16.dp), color = MaterialTheme.colorScheme.outlineVariant)
                                NavRow(R.drawable.ic_battery, "Battery settings", "Allow background activity if the phone stops responding while locked",
                                    trailing = R.drawable.ic_open_in_new) {
                                    startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.parse("package:$packageName")))
                                }
                            }
                        }
                        OutlinedButton(onClick = { unpairOpen = true }, modifier = Modifier.fillMaxWidth(),
                            colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error),
                            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)) { Text("Unpair this Mac") }
                    }
                    waiting -> {
                        Text("Compare the codes", style = MaterialTheme.typography.headlineSmall)
                        Text("Check that your Mac shows the same six digits, then choose Codes Match — Pair there.",
                            style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Surface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.surfaceContainer) {
                            Column(Modifier.padding(vertical = 32.dp, horizontal = 20.dp), horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.spacedBy(24.dp)) {
                                val code = comparisonCode.ifEmpty { "••••••" }
                                Text("${code.take(3)} ${code.drop(3)}", fontFamily = FontFamily.Monospace, fontSize = 44.sp, letterSpacing = 2.sp,
                                    color = MaterialTheme.colorScheme.primary)
                                LinearProgressIndicator(Modifier.fillMaxWidth(0.6f))
                                Text("Waiting for approval on your Mac", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                        OutlinedButton(onClick = { cancelled = true; pairingThread?.interrupt(); waiting = false; comparisonCode = "" },
                            modifier = Modifier.fillMaxWidth()) { Text("Cancel pairing") }
                    }
                    else -> {
                        Text(if (scanning) "Scan your Mac's code" else "Pair with your Mac", style = MaterialTheme.typography.headlineSmall)
                        Text("On your Mac, click DevSwitch in the menu bar and choose Pair Phone.",
                            style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        if (scanning) {
                            Scanner()
                            Text("Fit the whole code inside the frame. Hold the phone upright, about 20–40 cm from the screen.",
                                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            OutlinedButton(onClick = { scanning = false }, modifier = Modifier.fillMaxWidth()) { Text("Close camera") }
                        } else {
                            Surface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.surfaceContainer) {
                                Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                                    NumberedStep(1, "Scan the QR code on your Mac")
                                    NumberedStep(2, "Compare the six-digit codes")
                                    NumberedStep(3, "Approve the connection on your Mac")
                                }
                            }
                            Button(onClick = ::scan, modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp)) {
                                Icon(painterResource(R.drawable.ic_qr_code), contentDescription = null, Modifier.size(20.dp))
                                Spacer(Modifier.width(12.dp))
                                Text("Scan Mac QR code")
                            }
                        }
                        TextButton(onClick = { scanning = false; pasteOpen = true }, modifier = Modifier.fillMaxWidth()) { Text("Paste invitation instead") }
                        Text("Both devices need to be on the same Wi-Fi network.", Modifier.align(Alignment.CenterHorizontally),
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                if (errorText.isNotEmpty()) ProblemCard("Couldn't pair", errorText)
            }
        }
        if (pasteOpen) AlertDialog(onDismissRequest = { pasteOpen = false }, title = { Text("Paste invitation") },
            text = { OutlinedTextField(value = invitationText, onValueChange = { invitationText = it }, label = { Text("From Copy Invitation on your Mac") }, minLines = 3, maxLines = 6) },
            confirmButton = { TextButton(onClick = { pasteOpen = false; pair(invitationText); invitationText = "" }, enabled = invitationText.isNotBlank()) { Text("Connect") } },
            dismissButton = { TextButton(onClick = { pasteOpen = false; invitationText = "" }) { Text("Cancel") } })
        if (unpairOpen) AlertDialog(onDismissRequest = { unpairOpen = false }, title = { Text("Unpair this Mac?") }, text = { Text("It will no longer control developer settings.") },
            confirmButton = { TextButton(onClick = {
                stopService(Intent(this@PairingActivity, RemoteService::class.java)); PairStore.clear(this@PairingActivity)
                RemoteService.connectionState = "Not paired"; pairedName = null; unpairOpen = false
            }, colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) { Text("Unpair") } },
            dismissButton = { TextButton(onClick = { unpairOpen = false }) { Text("Cancel") } })
    }
    @Composable
    private fun Scanner() {
        val owner = LocalLifecycleOwner.current
        val barcode = remember {
            BarcodeView(this).apply {
                decoderFactory = DefaultDecoderFactory(listOf(BarcodeFormat.QR_CODE))
                cameraSettings.isContinuousFocusEnabled = true
                decodeSingle(object : BarcodeCallback {
                    override fun barcodeResult(result: BarcodeResult) { result.text?.let { value -> post { pair(value) } } }
                })
            }
        }
        DisposableEffect(owner, barcode) {
            val observer = LifecycleEventObserver { _, event ->
                when (event) { Lifecycle.Event.ON_RESUME -> barcode.resume(); Lifecycle.Event.ON_PAUSE -> barcode.pause(); else -> {} }
            }
            owner.lifecycle.addObserver(observer)
            if (owner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) barcode.resume()
            onDispose { owner.lifecycle.removeObserver(observer); barcode.pause() }
        }
        AndroidView(factory = { barcode }, modifier = Modifier.fillMaxWidth().aspectRatio(1f)
            .clip(RoundedCornerShape(24.dp)).background(Color.Black).border(2.dp, MaterialTheme.colorScheme.primary, RoundedCornerShape(24.dp)))
    }
    private fun pair(raw: String) {
        if (pairingThread?.isAlive == true) return
        cancelled = false
        scanning = false
        errorText = ""
        waiting = true
        pairingThread = Thread {
            try {
                require(raw.length <= 8192)
                val invitation = JSONObject(raw)
                require(invitation.getInt("version") == 1 && invitation.getString("app") == "devswitch")
                val url = Protocol.origin(invitation.getString("url")).toString()
                val expiry = invitation.getLong("expiresAt")
                require(expiry in (System.currentTimeMillis() / 1000 + 1)..(System.currentTimeMillis() / 1000 + 310))
                val pairId = UUID.fromString(invitation.getString("pairId")).toString()
                val secret = Protocol.decode(invitation.getString("secret"), 32)
                val id = UUID.randomUUID().toString()
                val nonce = Protocol.bytes(32)
                val hello = JSONObject().put("deviceId", id).put("deviceName", Build.MODEL.take(80)).put("clientNonce", Protocol.encode(nonce))
                val envelope = Protocol.seal(hello, secret, "devswitch/pair-request/v1/$pairId")
                val code = Protocol.comparison(secret, nonce)
                runOnUiThread { comparisonCode = code }
                while (!cancelled && System.currentTimeMillis() / 1000 < expiry) {
                    val (status, response) = Protocol.post(url, "/v1/pair/$pairId", envelope)
                    if (status == 200) {
                        val accepted = Protocol.open(response, secret, "devswitch/pair-response/v1/$pairId")
                        require(accepted.getString("deviceId") == id)
                        Protocol.decode(accepted.getString("key"), 32)
                        require(accepted.getString("desktopName").length <= 255)
                        if (cancelled) break
                        PairStore.save(this, accepted.put("url", url))
                        getSharedPreferences("devswitch", MODE_PRIVATE).edit().putBoolean("paused", false).apply()
                        runOnUiThread {
                            if (!isDestroyed) {
                                RemoteService.start(this); RemoteService.connectionState = "Connecting to your Mac…"
                                pairedName = accepted.getString("desktopName"); waiting = false; comparisonCode = ""
                            }
                        }
                        return@Thread
                    }
                    check(status == 202) { "Pairing rejected or expired" }
                    Thread.sleep(1500)
                }
                if (!cancelled) runOnUiThread { waiting = false; comparisonCode = ""; errorText = "This code expired. Click New code on your Mac, then scan again." }
            } catch (_: Exception) {
                if (!cancelled) runOnUiThread { waiting = false; comparisonCode = ""; errorText = "Could not connect. Keep both devices on the same Wi-Fi and allow local network access on your Mac. Then scan a fresh code." }
            }
        }.also { it.start() }
    }
    override fun onDestroy() { cancelled = true; pairingThread?.interrupt(); super.onDestroy() }
}
