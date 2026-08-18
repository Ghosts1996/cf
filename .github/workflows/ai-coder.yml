name: Super Multi-AI Safe Builder
on:
  workflow_dispatch:
    inputs:
      prompt:
        required: true

permissions:
  contents: write
  actions: write

jobs:
  super-ai-flow:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          submodules: true

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: 22

      - name: Set up Java Development Kit
        uses: actions/setup-java@v4
        with:
          distribution: 'zulu'
          java-version: '17'

      - name: Set up Flutter SDK
        uses: subosito/flutter-action@v2
        with:
          channel: 'stable'

      - name: Install Flutter Dependencies
        run: |
          cd app
          flutter pub get

      - name: 🧠 AI Code Optimization and Bug Fix (DeepSeek-R1)
        env:
          USER_PROMPT: ${{ github.event.inputs.prompt }}
          AITUNNEL_BASE_URL: ${{ secrets.AITUNNEL_BASE_URL }}
          AITUNNEL_API_KEY: ${{ secrets.AITUNNEL_API_KEY }}
        run: |
          echo "🚀 Кодируем файл и отправляем запрос на шлюз..."

          if [ -f "app/lib/services/tunnel_service.dart" ]; then
            TUNNEL_CODE_B64=$(base64 -w 0 < app/lib/services/tunnel_service.dart)
          else
            TUNNEL_CODE_B64=$(echo -n "Файл отсутствует, создай с нуля" | base64 -w 0)
          fi

          CLEAN_URL=$(echo "$AITUNNEL_BASE_URL" | sed 's/[/]*$//')

          SYSTEM_PROMPT='Ты элитный Flutter разработчик. Исправь код sing-box VLESS Reality, настрой DNS, настрой маршрутизацию и почини вылеты на Android 14+. Твой ответ должен состоять СТРОГО только из чистого кода Dart. Запрещено использовать маркдаун-теги вроде ```dart или ```, пиши только сырой код файла.'

          USER_CONTENT="Задача: ${USER_PROMPT}. Базовый код текущего файла в Base64 (декодируй перед анализом): ${TUNNEL_CODE_B64}"

          # jq -n --arg сам корректно экранирует кавычки, переносы строк,
          # обратные слэши и юникод — вручную строку JSON больше не собираем
          PAYLOAD=$(jq -n \
            --arg model "deepseek-r1" \
            --arg sys "$SYSTEM_PROMPT" \
            --arg usr "$USER_CONTENT" \
            '{model: $model, messages: [{role:"system", content:$sys}, {role:"user", content:$usr}]}')

          RESPONSE=$(curl -s -X POST "$CLEAN_URL/chat/completions" \
            -H "Authorization: Bearer $AITUNNEL_API_KEY" \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD")

          NEW_CODE=$(echo "$RESPONSE" | jq -r '.choices[0].message.content')

          if [ "$NEW_CODE" == "null" ] || [ -z "$NEW_CODE" ]; then
            echo "❌ Ошибка: Сервер вернул пустой ответ."
            echo "Ответ сервера: $RESPONSE"
            exit 1
          fi

          CLEAN_CODE=$(echo "$NEW_CODE" | sed '/^```/d')

          echo "✅ Код успешно сгенерирован моделью DeepSeek-R1!"

          mkdir -p app/lib/services
          echo "$CLEAN_CODE" > app/lib/services/tunnel_service.dart

          MANIFEST_PATH="app/android/app/src/main/AndroidManifest.xml"
          if [ -f "$MANIFEST_PATH" ]; then
            sed -i '/<service/ s/>/ android:foregroundServiceType="vpn">/' "$MANIFEST_PATH"
            echo "✅ AndroidManifest.xml успешно пропатчен!"
          fi

      - name: 🔍 Validate Generated Code (compile + static analysis)
        run: |
          cd app
          echo "🔎 Проверяем сгенерированный код на ошибки компиляции и типов..."

          # dart compile kernel ловит те же ошибки типов/компиляции,
          # что и полная сборка APK (как раз ту, что вызвала предыдущий баг),
          # но занимает секунды, а не минуты, и не собирает сам APK.
          if ! dart compile kernel lib/services/tunnel_service.dart -o /tmp/check.dill; then
            echo "❌ Сгенерированный код не компилируется. Отменяем сохранение в репозиторий."
            exit 1
          fi

          # flutter analyze дополнительно ловит ошибки типов и линт-предупреждения
          # по всему проекту (не только по одному файлу)
          if ! flutter analyze --no-fatal-infos; then
            echo "❌ Статический анализ нашёл ошибки. Отменяем сохранение в репозиторий."
            exit 1
          fi

          echo "✅ Код скомпилировался и прошёл статический анализ без ошибок."

      - name: Push Code Changes
        env:
          USER_PROMPT: ${{ github.event.inputs.prompt }}
        run: |
          git config --global user.name "AITUNNEL-Bot"
          git config --global user.email "bot@aitunnel.ru"
          git add .
          git commit -m "Super AI Safe Fix: $USER_PROMPT" || echo "No changes to commit"
          git push
