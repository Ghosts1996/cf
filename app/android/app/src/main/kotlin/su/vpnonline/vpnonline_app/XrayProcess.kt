package su.vpnonline.vpnonline_app

import android.content.Context
import java.io.File
import java.io.RandomAccessFile

/**
 * Ядро Xray отдельным процессом рядом с sing-box.
 *
 * sing-box (плагин) остаётся главным: держит VPN-интерфейс, маршруты и
 * группу локаций. Но часть серверов он подключить не умеет — например, с
 * «шифрованием VLESS» (`encryption=mlkem768x25519plus…`), которое есть только
 * в Xray. Такие серверы приложение отдаёт Xray: тот слушает SOCKS-порт на
 * 127.0.0.1, а sing-box ходит в этот порт как в обычный outbound. Плагин при
 * этом не меняется.
 *
 * Исполняемый файл лежит в APK как `libxray.so` (так Android раскладывает его
 * в каталог нативных библиотек, откуда запускать можно; из каталога данных
 * приложения запуск запрещён с Android 10). Свои соединения Xray открывает
 * мимо туннеля: приложение исключено из VPN, а процесс — его же UID.
 */
object XrayProcess {
    private const val BINARY = "libxray.so"
    private const val MAX_LOG_BYTES = 512 * 1024L

    @Volatile private var process: java.lang.Process? = null
    private var logOffset = 0L

    private fun binary(context: Context) = File(context.applicationInfo.nativeLibraryDir, BINARY)
    private fun dir(context: Context) = File(context.filesDir, "xray").apply { mkdirs() }
    private fun configFile(context: Context) = File(dir(context), "config.json")
    private fun logFile(context: Context) = File(dir(context), "xray.log")

    /** Есть ли Xray в этой сборке под эту архитектуру. */
    fun available(context: Context): Boolean = binary(context).isFile

    /** Запускает Xray с новым конфигом; прежний процесс, если был, гасится. */
    @Synchronized
    fun start(context: Context, config: String): Boolean {
        stopProcess()
        configFile(context).writeText(config)
        return launch(context)
    }

    /**
     * Сторож туннеля зовёт это каждые несколько секунд: процесс упал — поднять
     * снова с последним конфигом. Конфига нет — Xray сейчас не нужен.
     */
    @Synchronized
    fun ensureRunning(context: Context): String {
        if (alive(process)) return "running"
        if (!configFile(context).isFile) return "idle"
        return if (launch(context)) "restarted" else "failed"
    }

    /** Гасит Xray и забывает конфиг — до следующего [start] он не нужен. */
    @Synchronized
    fun stop(context: Context) {
        stopProcess()
        configFile(context).delete()
    }

    fun isRunning(): Boolean = alive(process)

    /** Новое в журнале Xray с прошлого вызова (не больше 64 КБ за раз). */
    @Synchronized
    fun readLog(context: Context): String {
        val file = logFile(context)
        if (!file.isFile) return ""
        val length = file.length()
        if (length < logOffset) logOffset = 0
        if (length == logOffset) return ""
        val size = minOf(length - logOffset, 64 * 1024L).toInt()
        val bytes = ByteArray(size)
        RandomAccessFile(file, "r").use {
            it.seek(logOffset)
            it.readFully(bytes)
        }
        logOffset += size
        return String(bytes, Charsets.UTF_8)
    }

    private fun launch(context: Context): Boolean {
        val bin = binary(context)
        if (!bin.isFile) return false
        val workDir = dir(context)
        val log = logFile(context)
        log.delete()
        logOffset = 0
        val builder = ProcessBuilder(bin.absolutePath, "run", "-c", configFile(context).absolutePath)
            .directory(workDir)
            .redirectErrorStream(true)
        builder.environment()["XRAY_LOCATION_ASSET"] = workDir.absolutePath
        val started = try {
            builder.start()
        } catch (e: Exception) {
            log.appendText("Не удалось запустить Xray: $e\n")
            return false
        }
        process = started
        pumpOutput(started, log)
        // Ошибка в конфиге видна сразу: процесс выходит за доли секунды.
        Thread.sleep(400)
        return alive(started)
    }

    /**
     * Вывод процесса — в файл журнала. Читать его обязательно: иначе буфер
     * канала заполнится и Xray встанет на записи в журнал.
     */
    private fun pumpOutput(target: java.lang.Process, log: File) {
        Thread {
            try {
                target.inputStream.bufferedReader().useLines { lines ->
                    for (line in lines) {
                        if (log.length() > MAX_LOG_BYTES) continue
                        log.appendText(line + "\n")
                    }
                }
            } catch (_: Exception) {
            }
        }.apply {
            isDaemon = true
            name = "xray-log"
            start()
        }
    }

    private fun stopProcess() {
        val current = process ?: return
        process = null
        current.destroy()
        // waitFor с таймаутом есть только с API 26, а приложение работает с 24.
        repeat(20) {
            if (!alive(current)) return
            Thread.sleep(50)
        }
        if (android.os.Build.VERSION.SDK_INT >= 26) current.destroyForcibly()
    }

    private fun alive(target: java.lang.Process?): Boolean {
        if (target == null) return false
        return try {
            target.exitValue()
            false
        } catch (_: IllegalThreadStateException) {
            true
        }
    }
}
