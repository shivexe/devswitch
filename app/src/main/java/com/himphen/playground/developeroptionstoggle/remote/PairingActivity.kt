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
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
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
import com.himphen.playground.developeroptionstoggle.ui.screen.DeviceMark
import com.himphen.playground.developeroptionstoggle.ui.screen.SectionLabel
import kotlinx.coroutines.delay
import org.json.JSONObject
import java.util.UUID

class PairingActivity : ComponentActivity() {
    private var pairedName by mutableStateOf<String?>(null)
    private var scanning by mutableStateOf(false)
    private var waiting by mutableStateOf(false)
    private var comparisonCode by mutableStateOf("")
    private var errorText by mutableStateOf("")
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
        setContent { DeveloperOptionsToggleTheme { ConnectionScreen() } }
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
        Scaffold(containerColor = MaterialTheme.colorScheme.background, topBar = {
            TopAppBar(title = { Text("Mac connection", fontWeight = FontWeight.SemiBold) },
                navigationIcon = { TextButton(onClick = { finish() }) { Text("Back") } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background))
        }) { inset ->
            Column(Modifier.fillMaxSize().padding(inset).verticalScroll(rememberScrollState()).padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp)) {
                when {
                    pairedName != null -> {
                        Box(Modifier.size(64.dp).background(MaterialTheme.colorScheme.primaryContainer, RoundedCornerShape(20.dp)), contentAlignment = Alignment.Center) {
                            DeviceMark(laptop = true, modifier = Modifier.size(32.dp))
                        }
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(pairedName.orEmpty(), style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold)
                            Text(connection, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Surface(shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.surface) {
                            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                                SectionLabel("MAC CONTROL")
                                Text(if (paused) "Connection paused" else "Ready when you are", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                                Text(if (paused) "Resume to receive commands from your Mac." else "Use the Mac menu bar to control your phone or switch development on and off.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                                if (paused) {
                                    Button(onClick = {
                                        getSharedPreferences("devswitch", MODE_PRIVATE).edit().putBoolean("paused", false).apply()
                                        paused = false
                                        RemoteService.start(this@PairingActivity)
                                    }, modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp), shape = RoundedCornerShape(14.dp)) { Text("Resume Mac control") }
                                } else {
                                    OutlinedButton(onClick = {
                                        getSharedPreferences("devswitch", MODE_PRIVATE).edit().putBoolean("paused", true).apply()
                                        paused = true
                                        stopService(Intent(this@PairingActivity, RemoteService::class.java))
                                    }, modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp), shape = RoundedCornerShape(14.dp)) { Text("Pause Mac control") }
                                }
                            }
                        }
                        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            SectionLabel("KEEP IT CONNECTED")
                            Text("Keep both devices on the same Wi-Fi. Allow background activity if your phone stops responding while locked.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            OutlinedButton(onClick = { startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.parse("package:$packageName"))) },
                                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp), shape = RoundedCornerShape(14.dp)) { Text("Open app battery settings") }
                        }
                        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                        TextButton(onClick = { unpairOpen = true }, colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) { Text("Unpair this Mac") }
                    }
                    waiting -> {
                        Text("Compare the codes", style = MaterialTheme.typography.headlineMedium)
                        Text("Check that the same six digits appear on your Mac. Then choose Codes match — pair there.", style = MaterialTheme.typography.bodyLarge)
                        Card(Modifier.fillMaxWidth(), shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
                            Column(Modifier.fillMaxWidth().padding(vertical = 32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                                Text(comparisonCode.ifEmpty { "••••••" }, fontFamily = FontFamily.Monospace, fontSize = 42.sp, letterSpacing = 4.sp, color = MaterialTheme.colorScheme.primary)
                            }
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                            CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                            Text("Waiting for approval on your Mac")
                        }
                        OutlinedButton(onClick = { cancelled = true; pairingThread?.interrupt(); waiting = false; comparisonCode = "" }) { Text("Cancel pairing") }
                    }
                    else -> {
                        Text(if (scanning) "Scan your Mac’s code" else "Pair with your Mac", style = MaterialTheme.typography.headlineMedium)
                        Text("On your Mac, open DevSwitch from the menu bar and choose Pair phone.", style = MaterialTheme.typography.bodyLarge)
                        if (scanning) {
                            Scanner()
                            Text("Fit the entire QR inside the frame. Hold the phone upright, about 20–40 cm from the screen.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                            TextButton(onClick = { scanning = false }) { Text("Close camera") }
                        } else {
                            Card(Modifier.fillMaxWidth(), shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
                                Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                                    SectionLabel("THREE QUICK STEPS")
                                    Text("01   Scan the QR code on your Mac")
                                    Text("02   Compare the six-digit codes")
                                    Text("03   Approve the connection on your Mac")
                                }
                            }
                            Button(onClick = ::scan, modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp), shape = RoundedCornerShape(14.dp)) { Text("Scan Mac QR code") }
                        }
                        TextButton(onClick = { scanning = false; pasteOpen = true }) { Text("Paste invitation instead") }
                        Text("Both devices need the same Wi-Fi network.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                if (errorText.isNotEmpty()) Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer)) {
                    Text(errorText, Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onErrorContainer)
                }
            }
        }
        if (pasteOpen) AlertDialog(onDismissRequest = { pasteOpen = false }, title = { Text("Paste invitation") },
            text = { OutlinedTextField(value = invitationText, onValueChange = { invitationText = it }, label = { Text("From Copy invitation on your Mac") }, minLines = 3, maxLines = 6) },
            confirmButton = { TextButton(onClick = { pasteOpen = false; pair(invitationText); invitationText = "" }, enabled = invitationText.isNotBlank()) { Text("Connect") } },
            dismissButton = { TextButton(onClick = { pasteOpen = false; invitationText = "" }) { Text("Cancel") } })
        if (unpairOpen) AlertDialog(onDismissRequest = { unpairOpen = false }, title = { Text("Unpair this Mac?") }, text = { Text("It will no longer control developer settings.") },
            confirmButton = { TextButton(onClick = {
                stopService(Intent(this@PairingActivity, RemoteService::class.java)); PairStore.clear(this@PairingActivity)
                RemoteService.connectionState = "Not paired"; pairedName = null; unpairOpen = false
            }) { Text("Unpair") } }, dismissButton = { TextButton(onClick = { unpairOpen = false }) { Text("Cancel") } })
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
            .clip(RoundedCornerShape(20.dp)).background(Color.Black).border(2.dp, MaterialTheme.colorScheme.primary, RoundedCornerShape(20.dp)))
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
