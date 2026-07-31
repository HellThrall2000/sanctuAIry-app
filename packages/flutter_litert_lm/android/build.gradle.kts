import org.jetbrains.kotlin.gradle.dsl.JvmTarget

group = "com.songhieu.flutter_litert_lm"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.2.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:8.11.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
    id("kotlin-android")
}

// Use the new compilerOptions DSL instead of the legacy
// `android { kotlinOptions { jvmTarget = "..." } }` block. The legacy form
// was deprecated in Kotlin 2.0 and removed in 2.3, so this keeps the build
// working when dependabot bumps kotlin-android across that boundary.
kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

android {
    namespace = "com.songhieu.flutter_litert_lm"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
        // Ship Proguard/R8 rules with the AAR so consumer apps automatically
        // keep the LiteRT-LM JNI surface (see consumer-rules.pro for the
        // explanation). Without this, release builds crash with
        // NoSuchMethodError on getters like SamplerConfig.getTopK().
        consumerProguardFiles("consumer-rules.pro")
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.useJUnitPlatform()
                it.outputs.upToDateWhen { false }
                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

dependencies {
    // LiteRT-LM Android SDK
    //
    // VENDORED CHANGE: 0.10.0 -> 0.13.1. 0.10.0 does not know the `gemma4`
    // model type and aborts inside nativeCreateEngine (SIGABRT) on our model.
    // Because Gradle compiles each module against its *declared* version while
    // packaging only the highest, leaving this at 0.10.0 while the app asked for
    // 0.13.1 produced a NoSuchMethodError on EngineConfig at runtime. The app's
    // `subprojects { force }` block papers over that; pinning it correctly here
    // means the two agree by construction. Keep both in step when upgrading.
    implementation("com.google.ai.edge.litertlm:litertlm-android:0.13.1")

    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.0.0")
}
