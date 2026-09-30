package com.himphen.playground.developeroptionstoggle.ui.viewmodel

import android.Manifest
import android.app.Application
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.himphen.playground.developeroptionstoggle.data.DeveloperSettingManager
import com.himphen.playground.developeroptionstoggle.data.DeveloperSettingsDataSource
import com.himphen.playground.developeroptionstoggle.data.SettingError
import com.himphen.playground.developeroptionstoggle.data.SettingReadResult
import com.himphen.playground.developeroptionstoggle.data.SettingTarget
import com.himphen.playground.developeroptionstoggle.data.SettingWriteResult
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class MainUiState(
    val isLoading: Boolean = true,
    val hasPermission: Boolean = false,
    val developerOptionsEnabled: Boolean = false,
    val usbDebuggingEnabled: Boolean = false,
    val wifiDebuggingEnabled: Boolean = false,
    val updatingSetting: SettingTarget? = null,
    val error: MainUiError? = null
)

sealed interface MainUiError {
    data object PermissionRequired : MainUiError

    data class ReadFailed(val setting: SettingTarget) : MainUiError

    data class WriteFailed(val setting: SettingTarget) : MainUiError

    data object SystemSettingsUnavailable : MainUiError
}

class MainViewModel @JvmOverloads constructor(
    application: Application,
    private val settingsDataSource: DeveloperSettingsDataSource =
        DeveloperSettingManager(application.contentResolver),
    private val permissionChecker: () -> Boolean = {
        ContextCompat.checkSelfPermission(
            application,
            Manifest.permission.WRITE_SECURE_SETTINGS   
        ) == PackageManager.PERMISSION_GRANTED
    }
) : AndroidViewModel(application) {

    private val _uiState = MutableStateFlow(MainUiState())
    val uiState: StateFlow<MainUiState> = _uiState.asStateFlow()

    init {
        refreshStatus()
    }

    fun refreshStatus() {
        viewModelScope.launch {
            _uiState.update { it.copy(isLoading = true, error = null) }

            if (!permissionChecker()) {
                _uiState.value = MainUiState(
                    isLoading = false,
                    hasPermission = false
                )
                return@launch
            }

            val results = SettingTarget.entries.associateWith(settingsDataSource::read)
            val firstFailure = results.entries.firstOrNull { (_, result) ->
                result is SettingReadResult.Failure
            }
            val permissionLost = results.values.any { result ->
                (result as? SettingReadResult.Failure)?.error ==
                    SettingError.PERMISSION_DENIED
            }

            _uiState.update { current ->
                current.copy(
                    isLoading = false,
                    hasPermission = !permissionLost,
                    developerOptionsEnabled = results[SettingTarget.DEVELOPER_OPTIONS]
                        .enabledOr(current.developerOptionsEnabled),
                    usbDebuggingEnabled = results[SettingTarget.USB_DEBUGGING]
                        .enabledOr(current.usbDebuggingEnabled),
                    wifiDebuggingEnabled = results[SettingTarget.WIFI_DEBUGGING]
                        .enabledOr(current.wifiDebuggingEnabled),
                    error = firstFailure?.let { (target, result) ->
                        result.toReadError(target)
                    }
                )
            }
        }
    }

    fun setDeveloperOptions(enabled: Boolean) {
        setSetting(SettingTarget.DEVELOPER_OPTIONS, enabled)
    }

    fun setUsbDebugging(enabled: Boolean) {
        setSetting(SettingTarget.USB_DEBUGGING, enabled)
    }

    fun setWifiDebugging(enabled: Boolean) {
        setSetting(SettingTarget.WIFI_DEBUGGING, enabled)
    }

    fun showSystemSettingsError() {
        _uiState.update { it.copy(error = MainUiError.SystemSettingsUnavailable) }
    }

    fun dismissError() {
        _uiState.update { it.copy(error = null) }
    }

    private fun setSetting(target: SettingTarget, enabled: Boolean) {
        viewModelScope.launch {
            if (!permissionChecker()) {
                _uiState.update {
                    it.copy(
                        hasPermission = false,
                        error = MainUiError.PermissionRequired
                    )
                }
                return@launch
            }

            _uiState.update {
                it.copy(
                    updatingSetting = target,
                    error = null
                )
            }

            when (val result = settingsDataSource.write(target, enabled)) {
                SettingWriteResult.Success -> {
                    _uiState.update { current ->
                        current.copy(
                            developerOptionsEnabled = if (
                                target == SettingTarget.DEVELOPER_OPTIONS
                            ) {
                                enabled
                            } else {
                                current.developerOptionsEnabled
                            },
                            usbDebuggingEnabled = if (
                                target == SettingTarget.USB_DEBUGGING
                            ) {
                                enabled
                            } else {
                                current.usbDebuggingEnabled
                            },
                            wifiDebuggingEnabled = if (
                                target == SettingTarget.WIFI_DEBUGGING
                            ) {
                                enabled
                            } else {
                                current.wifiDebuggingEnabled
                            },
                            updatingSetting = null,
                            error = null
                        )
                    }
                }

                is SettingWriteResult.Failure -> {
                    _uiState.update {
                        it.copy(
                            hasPermission = if (result.error == SettingError.PERMISSION_DENIED) {
                                false
                            } else {
                                it.hasPermission
                            },
                            updatingSetting = null,
                            error = result.toWriteError(target)
                        )
                    }
                }
            }
        }
    }

    private fun SettingReadResult.toReadError(target: SettingTarget): MainUiError {
        return when (this) {
            is SettingReadResult.Success -> error("Successful reads cannot become errors.")
            is SettingReadResult.Failure -> {
                if (error == SettingError.PERMISSION_DENIED) {
                    MainUiError.PermissionRequired
                } else {
                    MainUiError.ReadFailed(target)
                }
            }
        }
    }

    private fun SettingWriteResult.Failure.toWriteError(target: SettingTarget): MainUiError {
        return if (error == SettingError.PERMISSION_DENIED) {
            MainUiError.PermissionRequired
        } else {
            MainUiError.WriteFailed(target)
        }
    }

    private fun SettingReadResult?.enabledOr(fallback: Boolean): Boolean {
        return (this as? SettingReadResult.Success)?.enabled ?: fallback
    }
}
