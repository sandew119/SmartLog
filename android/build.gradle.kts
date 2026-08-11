allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()

rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

subprojects {
    project.evaluationDependsOn(":app")
}

// Every module compiles Java and Kotlin against the same JVM version.
//
// Without this the build fails on any plugin whose own Gradle file pins an
// older Java target than the JDK Kotlin defaults to -- tflite_flutter sets
// Java 11 while Kotlin follows the toolchain's 21, and Gradle refuses the
// mismatch. Pinning both here rather than per plugin means the next
// dependency with the same habit does not break the build again.
subprojects {
    // The Java side has to be set on the `android` extension, not on the
    // JavaCompile task: AGP configures the task from the extension after
    // this runs, so anything set on the task directly is overwritten.
    //
    // Reached dynamically rather than through an AGP type, because the class
    // that holds it has moved between AGP major versions and a hard
    // reference would break on the next upgrade.
    fun alignJavaTarget() {
        extensions.findByName("android")?.withGroovyBuilder {
            getProperty("compileOptions").withGroovyBuilder {
                setProperty("sourceCompatibility", JavaVersion.VERSION_17)
                setProperty("targetCompatibility", JavaVersion.VERSION_17)
            }
        }
    }

    // Only the plugin modules. `:app` has been evaluated already, because of
    // the `evaluationDependsOn(":app")` above, which both makes registering
    // an afterEvaluate on it an error and finalises its compileOptions --
    // and it sets 17 in its own build file regardless, so there is nothing
    // here for it.
    if (!state.executed) {
        afterEvaluate { alignJavaTarget() }
    }

    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>()
        .configureEach {
            compilerOptions {
                jvmTarget.set(
                    org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17,
                )
            }
        }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}