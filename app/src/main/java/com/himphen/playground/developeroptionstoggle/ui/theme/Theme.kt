package com.himphen.playground.developeroptionstoggle.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val Light = lightColorScheme(
    primary = Color(0xFF245DCC), onPrimary = Color.White,
    primaryContainer = Color(0xFFE7EEFF), onPrimaryContainer = Color(0xFF173E8B),
    background = Color(0xFFF5F6F9), onBackground = Color(0xFF172033),
    surface = Color.White, onSurface = Color(0xFF172033),
    surfaceVariant = Color(0xFFEAEDF3), onSurfaceVariant = Color(0xFF536075),
    outline = Color(0xFF778296), outlineVariant = Color(0xFFDCE1EA),
    secondary = Color(0xFF536075), secondaryContainer = Color(0xFFEAEDF3), onSecondaryContainer = Color(0xFF172033)
)
private val Dark = darkColorScheme(
    primary = Color(0xFFA8C5FF), onPrimary = Color(0xFF102F65),
    primaryContainer = Color(0xFF1C3257), onPrimaryContainer = Color(0xFFD5E3FF),
    background = Color(0xFF101318), onBackground = Color(0xFFE7EBF2),
    surface = Color(0xFF1B2028), onSurface = Color(0xFFE7EBF2),
    surfaceVariant = Color(0xFF272E39), onSurfaceVariant = Color(0xFFADB8CA),
    outline = Color(0xFF8995A9), outlineVariant = Color(0xFF343D4B),
    secondary = Color(0xFFADB8CA), secondaryContainer = Color(0xFF272E39), onSecondaryContainer = Color(0xFFE7EBF2)
)

@Composable
fun DeveloperOptionsToggleTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) Dark else Light, typography = Typography, content = content)
}
