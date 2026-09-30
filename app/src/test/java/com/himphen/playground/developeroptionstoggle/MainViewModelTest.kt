package com.himphen.playground.developeroptionstoggle

import android.app.Application
import com.himphen.playground.developeroptionstoggle.data.DeveloperSettingsDataSource
import com.himphen.playground.developeroptionstoggle.data.SettingError
import com.himphen.playground.developeroptionstoggle.data.SettingReadResult
import com.himphen.playground.developeroptionstoggle.data.SettingTarget
import com.himphen.playground.developeroptionstoggle.data.SettingWriteResult
import com.himphen.playground.developeroptionstoggle.ui.viewmodel.MainUiError
import com.himphen.playground.developeroptionstoggle.ui.viewmodel.MainViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class MainViewModelTest {

    private val testDispatcher = UnconfinedTestDispatcher()

    @Before
    fun setUp() {
        Dispatchers.setMain(testDispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun missingPermissionEntersReadOnlyState() = runTest {
        val dataSource = FakeDataSource()
        val viewModel = MainViewModel(
            application = Application(),
            settingsDataSource = dataSource,
            permissionChecker = { false }
        )

        advanceUntilIdle()

        assertFalse(viewModel.uiState.value.hasPermission)
        assertFalse(viewModel.uiState.value.isLoading)
        assertEquals(0, dataSource.readCount)
    }

    @Test
    fun failedWriteKeepsStateAndShowsError() = runTest {
        val dataSource = FakeDataSource(
            writeResult = SettingWriteResult.Failure(SettingError.WRITE_FAILED)
        )
        val viewModel = MainViewModel(
            application = Application(),
            settingsDataSource = dataSource,
            permissionChecker = { true }
        )

        advanceUntilIdle()
        viewModel.setDeveloperOptions(enabled = true)
        advanceUntilIdle()

        assertFalse(viewModel.uiState.value.developerOptionsEnabled)
        assertEquals(
            MainUiError.WriteFailed(SettingTarget.DEVELOPER_OPTIONS),
            viewModel.uiState.value.error
        )
    }

    @Test
    fun successfulWriteUpdatesTheMatchingSetting() = runTest {
        val dataSource = FakeDataSource()
        val viewModel = MainViewModel(
            application = Application(),
            settingsDataSource = dataSource,
            permissionChecker = { true }
        )

        advanceUntilIdle()
        viewModel.setWifiDebugging(enabled = true)
        advanceUntilIdle()

        assertTrue(viewModel.uiState.value.wifiDebuggingEnabled)
        assertEquals(SettingTarget.WIFI_DEBUGGING, dataSource.lastWrittenTarget)
        assertTrue(dataSource.lastWrittenValue == true)
    }

    @Test
    fun permissionFailureDuringWriteIsShownToTheUser() = runTest {
        val dataSource = FakeDataSource(
            writeResult = SettingWriteResult.Failure(SettingError.PERMISSION_DENIED)
        )
        val viewModel = MainViewModel(
            application = Application(),
            settingsDataSource = dataSource,
            permissionChecker = { true }
        )

        advanceUntilIdle()
        viewModel.setUsbDebugging(enabled = true)
        advanceUntilIdle()

        assertFalse(viewModel.uiState.value.hasPermission)
        assertEquals(MainUiError.PermissionRequired, viewModel.uiState.value.error)
    }

    private class FakeDataSource(
        private val writeResult: SettingWriteResult = SettingWriteResult.Success
    ) : DeveloperSettingsDataSource {
        var readCount = 0
        var lastWrittenTarget: SettingTarget? = null
        var lastWrittenValue: Boolean? = null

        override fun read(target: SettingTarget): SettingReadResult {
            readCount += 1
            return SettingReadResult.Success(enabled = false)
        }

        override fun write(target: SettingTarget, enabled: Boolean): SettingWriteResult {
            lastWrittenTarget = target
            lastWrittenValue = enabled
            return writeResult
        }
    }
}
