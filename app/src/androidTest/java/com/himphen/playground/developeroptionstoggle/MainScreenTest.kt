package com.himphen.playground.developeroptionstoggle

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import org.junit.Rule
import org.junit.Test

class MainScreenTest {

    @get:Rule
    val composeTestRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun systemSettingsShortcutIsVisible() {
        composeTestRule
            .onNodeWithText("Open system settings")
            .assertIsDisplayed()
    }
}
