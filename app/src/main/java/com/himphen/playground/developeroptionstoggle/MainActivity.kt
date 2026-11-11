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
        com.himphen.playground.developeroptionstoggle.remote.RemoteService.resume(this)
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
