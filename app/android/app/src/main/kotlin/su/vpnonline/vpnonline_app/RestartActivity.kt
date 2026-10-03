package su.vpnonline.vpnonline_app

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.os.Process

/// Перезапуск приложения целиком — последнее средство против зависшего ядра.
///
/// Ядро VPN живёт в процессе приложения. Если после неудачной гонки старта и
/// остановки сервиса в плагине осталось «осиротевшее» ядро, остановить его
/// изнутри нечем: ссылки на него у плагина уже нет, а служебный порт оно
/// держит до смерти процесса. Эта активность запускается в отдельном
/// процессе (android:process=":restart" в манифесте), завершает основной
/// процесс вместе с зависшим ядром и тут же открывает приложение заново.
/// Активность из видимого приложения в видимое — такой запуск Android
/// разрешает на любой версии, в отличие от будильников и фоновых запусков.
class RestartActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val mainPid = intent.getIntExtra(EXTRA_MAIN_PID, -1)
        if (mainPid > 0 && mainPid != Process.myPid()) {
            Process.killProcess(mainPid)
        }
        packageManager.getLaunchIntentForPackage(packageName)?.let {
            it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            startActivity(it)
        }
        finish()
        Runtime.getRuntime().exit(0)
    }

    companion object {
        const val EXTRA_MAIN_PID = "main_pid"
    }
}
