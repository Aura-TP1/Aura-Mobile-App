allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// vosk_flutter (sin actualizar hace ~3 años) no declara `namespace` en su
// build.gradle, algo que AGP 8+ exige (antes se infería del atributo
// `package` del AndroidManifest.xml). Sin esto, la build falla con
// "Namespace not specified" al configurar ese módulo. Se lo inyectamos acá
// para no tener que parchear el paquete en el pub cache de cada máquina.
subprojects {
    if (project.name == "vosk_flutter") {
        afterEvaluate {
            extensions.findByName("android")?.let { ext ->
                if (ext is com.android.build.gradle.BaseExtension && ext.namespace == null) {
                    ext.namespace = "org.vosk.vosk_flutter"
                }
            }
        }
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
