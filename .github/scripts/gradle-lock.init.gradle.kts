// Used by the dependency audit (.github/workflows/audit.yml), never by a normal build: turns on
// Gradle's dependency locking for the library's release runtime classpath (what an app gets) and
// its unit-test classpath, so `--write-locks` writes plugchoice/gradle.lockfile for osv-scanner.
// The library itself has no lockfile because React Native host apps build the same build file.
allprojects {
    configurations.matching { it.name == "releaseRuntimeClasspath" || it.name == "debugUnitTestRuntimeClasspath" }.configureEach {
        resolutionStrategy.activateDependencyLocking()
    }
}
