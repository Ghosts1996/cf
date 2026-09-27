package su.vpnonline.vpnonline_app

import androidx.core.content.FileProvider

/// FileProvider для передачи загруженного обновления системному установщику.
///
/// Отдельный подкласс, а не androidx.core.content.FileProvider напрямую:
/// манифесты библиотек склеиваются по имени класса провайдера, и если
/// какая-то из них уже объявила стандартный FileProvider со своими
/// настройками, два одинаковых объявления сломали бы сборку. У подкласса имя
/// своё, и конфликтовать ему не с чем.
///
/// Наружу открыта только папка updates/ в кэше приложения — см.
/// res/xml/update_paths.xml.
class UpdateFileProvider : FileProvider()
