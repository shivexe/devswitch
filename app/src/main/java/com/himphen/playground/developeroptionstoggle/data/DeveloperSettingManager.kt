package com.himphen.playground.developeroptionstoggle.data

import android.content.ContentResolver
import android.provider.Settings

enum class SettingTarget {
    DEVELOPER_OPTIONS,
    USB_DEBUGGING,
    WIFI_DEBUGGING
}

enum class SettingError {
    PERMISSION_DENIED,
    READ_FAILED,
    WRITE_FAILED
}

sealed interface SettingReadResult {
    data class Success(val enabled: Boolean) : SettingReadResult

    data class Failure(val error: SettingError) : SettingReadResult
}

sealed interface SettingWriteResult {
    data object Success : SettingWriteResult

    data class Failure(val error: SettingError) : SettingWriteResult
}

interface DeveloperSettingsDataSource {
    fun read(target: SettingTarget): SettingReadResult

    fun write(target: SettingTarget, enabled: Boolean): SettingWriteResult
}

class DeveloperSettingManager(
    private val contentResolver: ContentResolver
) : DeveloperSettingsDataSource {

    override fun read(target: SettingTarget): SettingReadResult {
        return readSetting(target.settingKey)
    }

    override fun write(target: SettingTarget, enabled: Boolean): SettingWriteResult {
        return writeSetting(target.settingKey, enabled)
    }

    private fun readSetting(key: String): SettingReadResult {
        return try {
            SettingReadResult.Success(
                Settings.Global.getInt(contentResolver, key, 0) == 1
            )
        } catch (_: SecurityException) {
            SettingReadResult.Failure(SettingError.PERMISSION_DENIED)
        } catch (_: RuntimeException) {
            SettingReadResult.Failure(SettingError.READ_FAILED)
        }
    }

    private fun writeSetting(key: String, enabled: Boolean): SettingWriteResult {
        return try {
            val updated = Settings.Global.putString(
                contentResolver,
                key,
                if (enabled) "1" else "0"
            )
            if (updated) {
                SettingWriteResult.Success
            } else {
                SettingWriteResult.Failure(SettingError.WRITE_FAILED)
            }
        } catch (_: SecurityException) {
            SettingWriteResult.Failure(SettingError.PERMISSION_DENIED)
        } catch (_: RuntimeException) {
            SettingWriteResult.Failure(SettingError.WRITE_FAILED)
        }
    }

    private val SettingTarget.settingKey: String
        get() = when (this) {
            SettingTarget.DEVELOPER_OPTIONS -> Settings.Global.DEVELOPMENT_SETTINGS_ENABLED
            SettingTarget.USB_DEBUGGING -> Settings.Global.ADB_ENABLED
            SettingTarget.WIFI_DEBUGGING -> WIFI_DEBUGGING_SETTING
        }

    private companion object {
        const val WIFI_DEBUGGING_SETTING = "adb_wifi_enabled"
    }
}
