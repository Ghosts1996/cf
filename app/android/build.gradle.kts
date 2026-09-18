allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

subprojects {
    // Патчим compileSdk только плагинам: :app задаёт его сам и к этому моменту
    // уже вычислен (evaluationDependsOn(":app") выше), а повторный
    // afterEvaluate на вычисленном проекте Gradle роняет сборку с
    // "Cannot run Project.afterEvaluate(Action) when the project is already evaluated".
    if (project.name != "app") {
        afterEvaluate {
            val android = extensions.findByName("android") as? com.android.build.gradle.BaseExtension
            if (android != null) {
                android.compileSdkVersion(36)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}