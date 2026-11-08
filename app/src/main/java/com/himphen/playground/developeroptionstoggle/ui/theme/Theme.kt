package com.himphen.playground.developeroptionstoggle.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val Light = lightColorScheme(
    primary = BrandBlue, onPrimary = Color.White,
    primaryContainer = Color(0xFFDAE2FF), onPrimaryContainer = Color(0xFF173E8B),
    secondaryContainer = Color(0xFFDCE2F9), onSecondaryContainer = Color(0xFF141B2C),
    background = Color(0xFFF9F9FF), onBackground = Color(0xFF1A1B20),
    surface = Color(0xFFF9F9FF), onSurface = Color(0xFF1A1B20),
    surfaceVariant = Color(0xFFE1E2EC), onSurfaceVariant = Color(0xFF44464F),
    surfaceContainerLow = Color(0xFFF3F3FA), surfaceContainer = Color(0xFFEDEDF4),
    surfaceContainerHigh = Color(0xFFE8E7EF), surfaceContainerHighest = Color(0xFFE2E2E9),
    outline = Color(0xFF757780), outlineVariant = Color(0xFFC5C6D0)
)
private val Dark = darkColorScheme(
    primary = BrandBlueDark, onPrimary = Color(0xFF102F65),
    primaryContainer = Color(0xFF2A4486), onPrimaryContainer = Color(0xFFDAE2FF),
    secondaryContainer = Color(0xFF3F4759), onSecondaryContainer = Color(0xFFDCE2F9),
    background = Color(0xFF121318), onBackground = Color(0xFFE2E2E9),
    surface = Color(0xFF121318), onSurface = Color(0xFFE2E2E9),
    surfaceVariant = Color(0xFF44464F), onSurfaceVariant = Color(0xFFC5C6D0),
    surfaceContainerLow = Color(0xFF1A1B20), surfaceContainer = Color(0xFF1E1F25),
    surfaceContainerHigh = Color(0xFF282A2F), surfaceContainerHighest = Color(0xFF33353A),
    outline = Color(0xFF8F9099), outlineVariant = Color(0xFF44464F)
)

@Composable
fun DeveloperOptionsToggleTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) Dark else Light, typography = Typography, content = content)
}
