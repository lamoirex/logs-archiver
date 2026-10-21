#!/bin/bash
# Автотесты для archive_logs.sh.
#
# Тест создаёт маленький настоящий раздел: файл-образ на 100 МБ с ext4,
# подключённый через mount. На обычной папке так не получится: df покажет
# размер всего диска, и порог 90% никогда не сработает.
#
# В каждом сценарии раздел наполняется логами, запускается основной
# скрипт, а потом тест сам пересчитывает файлы и архивы и сверяет
# с ожидаемым. Выводу основного скрипта тест не верит.
#
# Нужен root (для mount). Запуск: sudo bash tests/run_archiver_tests.sh

SCRIPT="$(dirname "$0")/../scripts/archive_logs.sh"
TEST_ROOT="/tmp/archive_logs_test"
IMAGE="$TEST_ROOT/disk.img"
LOGS="$TEST_ROOT/LOGS"
OUTPUT="$TEST_ROOT/output.txt"

AUTH="auth_service"
DATA="data_process_service"
SYSTEM="system_event_handler_service"

tests_total=0
tests_passed=0
errors=0

# ---------- Подготовка раздела ----------

if [ "$(id -u)" -ne 0 ]; then
    echo "Тестам нужен root, запустите: sudo bash $0"
    exit 1
fi

if [ ! -f "$SCRIPT" ]; then
    echo "Не найден основной скрипт: $SCRIPT"
    exit 1
fi

# Если прошлый запуск упал посередине, убираем то, что от него осталось
if mountpoint -q "$LOGS"; then
    umount "$LOGS"
fi
rm -rf "$TEST_ROOT"
mkdir -p "$LOGS"

# Файл из нулей на 100 МБ превращаем в раздел ext4.
# -m 0: не оставлять 5% места под root, чтобы проценты считались просто
dd if=/dev/zero of="$IMAGE" bs=1M count=100 2>/dev/null
mkfs.ext4 -q -m 0 "$IMAGE"
mount -o loop "$IMAGE" "$LOGS"
if [ $? -ne 0 ]; then
    echo "Не удалось подключить тестовый раздел"
    exit 1
fi

DISK_KB=$(df -P -k "$LOGS" | tail -n 1 | tr -s ' ' | cut -d ' ' -f 2)
# Один лог-файл = 1% раздела, так сценарии удобно описывать в процентах
FILE_KB=$((DISK_KB / 100))
# Лимит папки тест считает сам, так же как сказано в задании: 90% / 3
FOLDER_LIMIT_KB=$((DISK_KB * 90 / 100 / 3))

echo "Тестовый раздел: $DISK_KB КБ, один файл: $FILE_KB КБ, лимит папки: $FOLDER_LIMIT_KB КБ"
echo

# ---------- Вспомогательные функции ----------

# Имя i-го лога компоненты. Чем больше i, тем файл новее (разница в 1 час)
log_name() {
    component="$1"
    i="$2"
    timestamp=$((1760000000 + i * 3600))
    day=$(date -d "@$timestamp" '+%Y_%m_%d')
    echo "${component}_${day}_${timestamp}.log"
}

# Создать count логов компоненты, каждый размером size_kb
make_logs() {
    component="$1"
    count="$2"
    size_kb="$3"
    mkdir -p "$LOGS/$component"
    i=1
    while [ $i -le $count ]; do
        name=$(log_name "$component" $i)
        dd if=/dev/zero of="$LOGS/$component/$name" bs=1K count="$size_kb" 2>/dev/null
        i=$((i + 1))
    done
}

# Очистить раздел перед следующим тестом
clean_disk() {
    rm -rf "$LOGS/$AUTH" "$LOGS/$DATA" "$LOGS/$SYSTEM" "$LOGS/other_data.bin"
}

count_logs() {
    ls "$1" | grep -c '\.log$'
}

count_archives() {
    if [ -d "$1/archive" ]; then
        ls "$1/archive" | grep -c '\.tar\.gz$'
    else
        echo 0
    fi
}

run_script() {
    bash "$SCRIPT" "$@" > "$OUTPUT" 2>&1
    exit_code=$?
}

expect_equal() {
    what="$1"
    actual="$2"
    expected="$3"
    if [ "$actual" != "$expected" ]; then
        echo "    ошибка: $what = $actual, ожидалось $expected"
        errors=$((errors + 1))
    fi
}

expect_output() {
    text="$1"
    if ! grep -q "$text" "$OUTPUT"; then
        echo "    ошибка: в выводе нет строки \"$text\""
        errors=$((errors + 1))
    fi
}

# Папка не тронута: все логи на месте, архивов нет
check_untouched() {
    component="$1"
    created="$2"
    expect_equal "$component: логов" "$(count_logs "$LOGS/$component")" "$created"
    expect_equal "$component: архивов" "$(count_archives "$LOGS/$component")" "0"
}

# Папка заархивирована правильно
check_archived() {
    component="$1"
    created="$2"
    dir="$LOGS/$component"

    left=$(count_logs "$dir")
    archived=$((created - left))
    if [ "$archived" -le 0 ]; then
        echo "    ошибка: $component: из папки не убран ни один лог"
        errors=$((errors + 1))
        return
    fi

    # Ровно один архив, и в нём столько файлов, сколько пропало из папки
    expect_equal "$component: архивов" "$(count_archives "$dir")" "1"
    archive=$(ls "$dir"/archive/*.tar.gz | head -n 1)
    in_archive=$(tar -tzf "$archive" | grep -c '\.log$')
    expect_equal "$component: файлов в архиве" "$in_archive" "$archived"

    # Заархивированы именно самые старые: файл номер archived удалён,
    # а следующий за ним (archived + 1) остался
    last_archived=$(log_name "$component" $archived)
    first_left=$(log_name "$component" $((archived + 1)))
    if [ -f "$dir/$last_archived" ]; then
        echo "    ошибка: $component: старый файл $last_archived не удалён"
        errors=$((errors + 1))
    fi
    if [ ! -f "$dir/$first_left" ]; then
        echo "    ошибка: $component: удалён лишний файл $first_left"
        errors=$((errors + 1))
    fi

    # Самый новый файл на месте
    newest=$(log_name "$component" $created)
    if [ ! -f "$dir/$newest" ]; then
        echo "    ошибка: $component: удалён самый новый файл"
        errors=$((errors + 1))
    fi

    # Папка вернулась в свой лимит
    folder_kb=$(du -s -k "$dir" | cut -f 1)
    if [ "$folder_kb" -gt "$FOLDER_LIMIT_KB" ]; then
        echo "    ошибка: $component: $folder_kb КБ, больше лимита $FOLDER_LIMIT_KB КБ"
        errors=$((errors + 1))
    fi
}

start_test() {
    tests_total=$((tests_total + 1))
    errors=0
    clean_disk
    echo "Тест $tests_total: $1"
}

finish_test() {
    if [ "$errors" -eq 0 ]; then
        echo "    PASS"
        tests_passed=$((tests_passed + 1))
    else
        echo "    FAIL, вывод основного скрипта:"
        while read line; do
            echo "      $line"
        done < "$OUTPUT"
    fi
    echo
}

# ---------- Сценарии ----------

start_test "раздел заполнен на 70%, ничего не трогаем (хотя auth больше 1/3)"
make_logs $AUTH 50 $FILE_KB
make_logs $DATA 10 $FILE_KB
make_logs $SYSTEM 10 $FILE_KB
run_script "$LOGS" 90
expect_equal "код выхода" "$exit_code" "0"
expect_output "Порог не превышен"
check_untouched $AUTH 50
check_untouched $DATA 10
check_untouched $SYSTEM 10
finish_test

start_test "92%, превышена только папка auth, архивируется только она"
make_logs $AUTH 52 $FILE_KB
make_logs $DATA 25 $FILE_KB
make_logs $SYSTEM 15 $FILE_KB
run_script "$LOGS" 90
expect_equal "код выхода" "$exit_code" "0"
check_archived $AUTH 52
check_untouched $DATA 25
check_untouched $SYSTEM 15
finish_test

start_test "92%, превышены две папки, архивируются обе"
make_logs $AUTH 40 $FILE_KB
make_logs $DATA 40 $FILE_KB
make_logs $SYSTEM 12 $FILE_KB
run_script "$LOGS" 90
expect_equal "код выхода" "$exit_code" "0"
check_archived $AUTH 40
check_archived $DATA 40
check_untouched $SYSTEM 12
finish_test

start_test "93%, но место занял чужой файл, ни одна папка не превысила 1/3"
make_logs $AUTH 29 $FILE_KB
make_logs $DATA 29 $FILE_KB
make_logs $SYSTEM 29 $FILE_KB
dd if=/dev/zero of="$LOGS/other_data.bin" bs=1K count=$((FILE_KB * 6)) 2>/dev/null
run_script "$LOGS" 90
expect_equal "код выхода" "$exit_code" "0"
expect_output "Порог превышен"
check_untouched $AUTH 29
check_untouched $DATA 29
check_untouched $SYSTEM 29
finish_test

start_test "в auth один огромный файл (текущий), его не трогаем"
make_logs $AUTH 1 $((FILE_KB * 45))
make_logs $DATA 25 $FILE_KB
make_logs $SYSTEM 22 $FILE_KB
run_script "$LOGS" 90
expect_equal "код выхода" "$exit_code" "0"
expect_output "нечего архивировать"
check_untouched $AUTH 1
check_untouched $DATA 25
check_untouched $SYSTEM 22
finish_test

start_test "неправильные аргументы: ошибка, ничего не трогаем"
make_logs $AUTH 52 $FILE_KB
make_logs $DATA 25 $FILE_KB
make_logs $SYSTEM 15 $FILE_KB
run_script "$LOGS" abc
expect_equal "код выхода для порога abc" "$exit_code" "1"
run_script "$LOGS" 150
expect_equal "код выхода для порога 150" "$exit_code" "1"
run_script "$TEST_ROOT/no_such_folder" 90
expect_equal "код выхода для несуществующей папки" "$exit_code" "1"
check_untouched $AUTH 52
check_untouched $DATA 25
check_untouched $SYSTEM 15
finish_test

# ---------- Итог и уборка ----------

umount "$LOGS"
rm -rf "$TEST_ROOT"

echo "Пройдено тестов: $tests_passed из $tests_total"
if [ "$tests_passed" -ne "$tests_total" ]; then
    exit 1
fi
exit 0
