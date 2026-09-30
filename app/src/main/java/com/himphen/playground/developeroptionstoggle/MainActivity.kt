package com.himphen.playground.developeroptionstoggle

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.enableEdgeToEdge
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import com.himphen.playground.developeroptionstoggle.ui.screen.MainScreen
import com.himphen.playground.developeroptionstoggle.ui.theme.DeveloperOptionsToggleTheme
import com.himphen.playground.developeroptionstoggle.ui.viewmodel.MainViewModel

class MainActivity : ComponentActivity() {

    private val viewModel: MainViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // Resume an existing, unpaused pairing when opening after an app update.
        try {
            if (!getSharedPreferences("devswitch", MODE_PRIVATE).getBoolean("paused", false) &&
                com.himphen.playground.developeroptionstoggle.remote.PairStore.load(this) != null) {
                com.himphen.playground.developeroptionstoggle.remote.RemoteService.start(this)
            }
        } catch (_: Exception) { /* The connection screen provides an explicit Resume action. */ }
        setContent {
            DeveloperOptionsToggleTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    MainScreen(viewModel = viewModel)
                }
            }
        }
    }
}
