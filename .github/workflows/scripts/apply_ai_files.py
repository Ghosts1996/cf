#!/usr/bin/env python3
"""
Парсит ответ AI (текст в формате блоков `=== FILE: <путь> === ... === END FILE ===`)
и записывает КАЖДЫЙ файл на диск — везде в репозитории, КРОМЕ:
  - .github/**            — сам CI-пайплайн; скрипт, который сейчас выполняется,
                             не должен мочь переписать самого себя;
  - .git/**                — служебные данные git;
  - файлов-секретов (*.env, *.pem, *.key, *.jks, *.keystore, *.p12, *.pfx);
  - путей, выходящих за пределы репозитория (".." / абсолютные пути).

Это единственная сознательная граница безопасности. Всё остальное применяется
без ограничений — в соответствии с тем, что пользователь дал AI полный доступ
к репозиторию.

Использование:
    python3 apply_ai_files.py <путь_к_ответу_ai.txt> <путь_к_логу_изменённых_файлов.txt>
"""
import os
import re
import sys

DENY_DIR_PREFIXES = (".github/", ".git/")
DENY_EXTENSIONS = (".env", ".pem", ".key", ".jks", ".keystore", ".p12", ".pfx")

FILE_BLOCK_RE = re.compile(
    r"^=== FILE: (?P<path>.+?) ===\n(?P<content>.*?)\n=== END FILE ===\s*$",
    re.DOTALL | re.MULTILINE,
)


def is_allowed(path: str) -> bool:
    norm = os.path.normpath(path)

    # Не даём выйти за пределы репозитория.
    if norm.startswith("..") or os.path.isabs(norm):
        return False

    # Запрещённые каталоги (сам CI-пайплайн, служебные данные git).
    norm_with_slash = norm + "/"
    if any(norm_with_slash.startswith(p) or norm == p.rstrip("/") for p in DENY_DIR_PREFIXES):
        return False

    # Запрещённые файлы-секреты (по расширению или суффиксу вида *.env.local).
    lower = norm.lower()
    if lower.endswith(DENY_EXTENSIONS) or ".env." in os.path.basename(lower) or os.path.basename(lower) == ".env":
        return False

    return True


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: apply_ai_files.py <ai_response.txt> <changed_files_log.txt>", file=sys.stderr)
        return 2

    src_path, log_path = sys.argv[1], sys.argv[2]

    with open(src_path, "r", encoding="utf-8") as f:
        text = f.read()

    changed = []
    skipped = []

    for match in FILE_BLOCK_RE.finditer(text):
        raw_path = match.group("path").strip()
        content = match.group("content")
        norm = os.path.normpath(raw_path)

        if not is_allowed(raw_path):
            skipped.append(raw_path)
            continue

        out_dir = os.path.dirname(norm) or "."
        os.makedirs(out_dir, exist_ok=True)
        with open(norm, "w", encoding="utf-8") as out:
            out.write(content if content.endswith("\n") else content + "\n")
        changed.append(norm)

    with open(log_path, "w", encoding="utf-8") as log:
        for p in changed:
            log.write(p + "\n")

    print(f"✅ Изменено файлов: {len(changed)}")
    for p in changed:
        print(f"   ✏️  {p}")

    if skipped:
        print(
            f"⚠️ Пропущено (запрещённые пути — .github/, .git/ или файлы-секреты): {len(skipped)}"
        )
        for p in skipped:
            print(f"   🚫 {p}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())