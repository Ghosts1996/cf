#!/usr/bin/env python3
"""
Парсит ответ AI (текст в формате блоков `=== FILE: <путь> === ... === END FILE ===`)
и записывает КАЖДЫЙ файл на диск — но только если путь входит в allowlist.

Это осознанная граница безопасности: даже если AI предложит поменять что-то
вне app/lib/, app/android/ или app/pubspec.yaml (например, файлы workflow
в .github/, деплой-скрипты, секреты) — такие блоки будут проигнорированы
и явно залогированы, а не применены молча.

Использование:
    python3 apply_ai_files.py <путь_к_ответу_ai.txt> <путь_к_логу_изменённых_файлов.txt>
"""
import os
import re
import sys

ALLOWED_PREFIXES = ("app/lib/", "app/android/")
ALLOWED_EXACT = ("app/pubspec.yaml",)

FILE_BLOCK_RE = re.compile(
    r"^=== FILE: (?P<path>.+?) ===\n(?P<content>.*?)\n=== END FILE ===\s*$",
    re.DOTALL | re.MULTILINE,
)


def is_allowed(path: str) -> bool:
    norm = os.path.normpath(path)
    if norm.startswith("..") or os.path.isabs(norm):
        return False
    return norm.startswith(ALLOWED_PREFIXES) or norm in ALLOWED_EXACT


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
            f"⚠️ Пропущено (вне разрешённых путей app/lib/, app/android/, "
            f"app/pubspec.yaml): {len(skipped)}"
        )
        for p in skipped:
            print(f"   🚫 {p}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
