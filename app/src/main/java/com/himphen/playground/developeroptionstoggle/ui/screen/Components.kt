package com.himphen.playground.developeroptionstoggle.ui.screen

import androidx.annotation.DrawableRes
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.himphen.playground.developeroptionstoggle.R
import com.himphen.playground.developeroptionstoggle.ui.theme.Connected
import com.himphen.playground.developeroptionstoggle.ui.theme.ConnectedDark

// RemoteService reports a sentence; only "Connected to …" means the Mac link is live.
fun isConnected(state: String) = state.startsWith("Connected")

@Composable
fun SectionHeader(text: String, modifier: Modifier = Modifier) {
    Text(text, modifier.padding(start = 16.dp, bottom = 8.dp), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
}

@Composable
fun GroupCard(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Surface(modifier.fillMaxWidth(), shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.surfaceContainer) {
        Column(content = content)
    }
}

@Composable
fun IconBadge(@DrawableRes icon: Int, modifier: Modifier = Modifier, size: Dp = 40.dp,
              container: Color = MaterialTheme.colorScheme.secondaryContainer,
              content: Color = MaterialTheme.colorScheme.onSecondaryContainer) {
    Box(modifier.size(size).background(container, CircleShape), contentAlignment = Alignment.Center) {
        Icon(painterResource(icon), contentDescription = null, Modifier.size(size * 0.5f), tint = content)
    }
}

@Composable
fun StatusDot(online: Boolean, modifier: Modifier = Modifier) {
    val color = if (online) (if (isSystemInDarkTheme()) ConnectedDark else Connected) else MaterialTheme.colorScheme.outline
    Box(modifier.size(8.dp).background(color, CircleShape))
}

@Composable
fun SwitchRow(@DrawableRes icon: Int, title: String, supporting: String, checked: Boolean, enabled: Boolean, onCheckedChange: (Boolean) -> Unit,
              emphasize: Boolean = false) {
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = {
            if (emphasize) Text(supporting, color = MaterialTheme.colorScheme.primary, fontWeight = FontWeight.Medium) else Text(supporting)
        },
        leadingContent = { Icon(painterResource(icon), contentDescription = null) },
        trailingContent = { Switch(checked = checked, onCheckedChange = null, enabled = enabled) },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        modifier = Modifier.toggleable(value = checked, enabled = enabled, role = Role.Switch, onValueChange = onCheckedChange)
    )
}

@Composable
fun NavRow(@DrawableRes icon: Int, title: String, supporting: String? = null, @DrawableRes trailing: Int = R.drawable.ic_chevron_right, onClick: () -> Unit) {
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = supporting?.let { { Text(it) } },
        leadingContent = { Icon(painterResource(icon), contentDescription = null) },
        trailingContent = { Icon(painterResource(trailing), contentDescription = null, Modifier.size(20.dp)) },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        modifier = Modifier.clickable(onClick = onClick)
    )
}

@Composable
fun NumberedStep(number: Int, text: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Box(Modifier.size(28.dp).background(MaterialTheme.colorScheme.secondaryContainer, CircleShape), contentAlignment = Alignment.Center) {
            Text("$number", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSecondaryContainer)
        }
        Text(text, style = MaterialTheme.typography.bodyLarge)
    }
}

@Composable
fun ProblemCard(title: String, message: String, modifier: Modifier = Modifier, actions: @Composable RowScope.() -> Unit = {}, extra: @Composable ColumnScope.() -> Unit = {}) {
    Surface(modifier.fillMaxWidth(), shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.errorContainer,
        contentColor = MaterialTheme.colorScheme.onErrorContainer) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Icon(painterResource(R.drawable.ic_warning), contentDescription = null, Modifier.size(20.dp))
                Text(title, style = MaterialTheme.typography.titleMedium)
            }
            Text(message, style = MaterialTheme.typography.bodyMedium)
            extra()
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End, content = actions)
        }
    }
}
