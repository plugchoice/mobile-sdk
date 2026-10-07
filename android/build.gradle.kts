import com.vanniktech.maven.publish.AndroidSingleVariantLibrary
import com.vanniktech.maven.publish.JavadocJar
import com.vanniktech.maven.publish.MavenPublishBaseExtension
import com.vanniktech.maven.publish.SourcesJar

plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.maven.publish) apply false
}

// Publishing `com.plugchoice:plugchoice` to Maven Central (through the Central Portal) or to the
// local Maven repository:
//
//   ./gradlew :plugchoice:publishAndReleaseToMavenCentral --no-configuration-cache   (CI)
//   ./gradlew :plugchoice:publishToMavenLocal
//
// Set up here rather than in plugchoice/build.gradle.kts, because that file is also built inside
// React Native host apps (as :plugchoice-sdk), which don't have this plugin. The group and version
// come from plugchoice/build.gradle.kts.
//
// Maven Central needs `mavenCentralUsername` and `mavenCentralPassword` (a Central Portal token),
// and signed artifacts: with `signingInMemoryKey` (an ASCII-armoured key) and
// `signingInMemoryKeyPassword` every publication is signed; without them (locally) nothing is.
// CI passes them as ORG_GRADLE_PROJECT_<name> environment variables.
project(":plugchoice") {
    apply(plugin = "com.vanniktech.maven.publish")
    pluginManager.withPlugin("com.android.library") {
        extensions.configure<MavenPublishBaseExtension> {
            configure(
                AndroidSingleVariantLibrary(
                    javadocJar = JavadocJar.Javadoc(),
                    sourcesJar = SourcesJar.Sources(),
                    variant = "release",
                ),
            )
            publishToMavenCentral(automaticRelease = true)
            if (providers.gradleProperty("signingInMemoryKey").isPresent) {
                signAllPublications()
            }
            coordinates(artifactId = "plugchoice")
            pom {
                name.set("Plugchoice SDK")
                description.set("Connect EV chargers to Plugchoice from an Android app.")
                url.set("https://github.com/plugchoice/mobile-sdk")
                licenses {
                    license {
                        name.set("MIT License")
                        url.set("https://opensource.org/licenses/MIT")
                        distribution.set("repo")
                    }
                }
                developers {
                    developer {
                        id.set("plugchoice")
                        name.set("Plugchoice")
                        organization.set("Volt Time B.V.")
                        url.set("https://plugchoice.com")
                    }
                }
                scm {
                    url.set("https://github.com/plugchoice/mobile-sdk")
                    connection.set("scm:git:git://github.com/plugchoice/mobile-sdk.git")
                    developerConnection.set("scm:git:ssh://git@github.com/plugchoice/mobile-sdk.git")
                }
            }
        }
    }
}
