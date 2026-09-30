import org.jetbrains.kotlin.gradle.dsl.JvmTarget

val defaultReleaseVersion = rootProject.file("VERSION").readText().trim()
private val DEFAULT_VERSION_CODE = 1
private val releaseVersionPattern = Regex("""\d+\.\d+\.\d+""")

private fun parseReleaseVersion(rawVersion: String?, fallback: String): String {
    val version = rawVersion
        ?.trim()
        ?.takeUnless { it.isEmpty() }
        ?.removePrefix("v")
        ?: fallback

    require(releaseVersionPattern.matches(version)) {
        "ANDROID_VERSION_NAME must use MAJOR.MINOR.PATCH format (received: '$rawVersion')."
    }
    return version
}

private fun parseVersionCode(rawVersionCode: String?): Int {
    val value = rawVersionCode
        ?.trim()
        ?.takeUnless { it.isEmpty() }
        ?: return DEFAULT_VERSION_CODE
    val versionCode = value.toIntOrNull()

    require(versionCode != null && versionCode > 0) {
        "ANDROID_VERSION_CODE must be a positive integer (received: '$rawVersionCode')."
    }
    return versionCode
}

val releaseKeystorePath = providers.gradleProperty("releaseKeystorePath").orNull
    ?: providers.environmentVariable("RELEASE_KEYSTORE_PATH").orNull
val releaseStorePassword = providers.gradleProperty("releaseStorePassword").orNull
    ?: providers.environmentVariable("RELEASE_STORE_PASSWORD").orNull
val releaseKeyAlias = providers.gradleProperty("releaseKeyAlias").orNull
    ?: providers.environmentVariable("RELEASE_KEY_ALIAS").orNull
val releaseKeyPassword = providers.gradleProperty("releaseKeyPassword").orNull
    ?: providers.environmentVariable("RELEASE_KEY_PASSWORD").orNull
val releaseSigningReady = listOf(
    releaseKeystorePath,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword
).all { !it.isNullOrBlank() }
val releaseVersion = parseReleaseVersion(
    providers.environmentVariable("ANDROID_VERSION_NAME").orNull, defaultReleaseVersion
)
val releaseVersionCode = parseVersionCode(
    providers.environmentVariable("ANDROID_VERSION_CODE").orNull
)

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.himphen.playground.developeroptionstoggle"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.himphen.playground.developeroptionstoggle"
        minSdk = 29
        targetSdk = 37
        versionCode = releaseVersionCode
        versionName = releaseVersion

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables {
            useSupportLibrary = true
        }
    }

    signingConfigs {
        if (releaseSigningReady) {
            create("release") {
                storeFile = file(releaseKeystorePath!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            if (releaseSigningReady) {
                signingConfig = signingConfigs.getByName("release")
            }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
    lint {
        // These bundled detectors crash while reading Kotlin 1.9 metadata.
        disable += "FlowOperatorInvokedInComposition"
        disable += "StateFlowValueCalledInComposition"
        disable += "CoroutineCreationDuringComposition"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
        compose = true
    }
}

tasks.register("printVersionName") {
    doLast {
        println(android.defaultConfig.versionName)
    }
}

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.JVM_17
    }
}

dependencies {
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    implementation(libs.androidx.core.ktx)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.ui)
    implementation(libs.androidx.ui.graphics)
    implementation(libs.androidx.ui.tooling.preview)
    implementation(libs.androidx.material3)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.viewmodel.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.glance)
    implementation(libs.androidx.glance.appwidget)
    implementation(libs.androidx.glance.material3)
    implementation(libs.androidx.glance.appwidget.proto)


    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
    androidTestImplementation(libs.androidx.ui.test.junit4)
    debugImplementation(libs.androidx.ui.tooling)
    debugImplementation(libs.androidx.ui.test.manifest)
}

// Ship the notices with APKs as well as the source distribution.
val prepareLicenseAssets by tasks.registering(Sync::class) {
    from(rootProject.file("LICENSE"), rootProject.file("THIRD_PARTY_NOTICES.md"))
    from(rootProject.file("licenses"))
    into(layout.buildDirectory.dir("generated/licenseAssets/licenses"))
}
android.sourceSets.getByName("main").assets.srcDir(layout.buildDirectory.dir("generated/licenseAssets").get().asFile)
tasks.named("preBuild") { dependsOn(prepareLicenseAssets) }
