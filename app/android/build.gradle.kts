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
    // [ИСПРАВЛЕНО] :app уже задаёт compileSdk = 36 сам в app/build.gradle.kts и к моменту
    // этого блока уже вычислен (см. evaluationDependsOn(":app") выше) — повторный
    // afterEvaluate на уже вычисленном проекте Gradle запрещает и роняет сборку
    // ("Cannot run Project.afterEvaluate(Action) when the project is already evaluated").
    // Патчим compileSdk только остальным подпроектам (плагинам), :app пропускаем.
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