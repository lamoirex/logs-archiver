#!/bin/bash

LOGS_DIR="/LOGS"
THRESHOLD=90
COMPONENTS="auth_service data_process_service system_event_handler_service"

TARGET_PERCENT=80

had_errors=0

if [ -n "$1" ]; then
    LOGS_DIR="$1"
fi
if [ -n "$2" ]; then
    THRESHOLD="$2"
fi

if [ ! -d "$LOGS_DIR" ]; then
    echo "Ошибка: папка $LOGS_DIR не найдена"
    exit 1
fi

if ! echo "$THRESHOLD" | grep -q '^[1-9][0-9]*$'; then
    echo "Ошибка: порог должен быть целым числом без нулей впереди, а получено: $THRESHOLD"
    exit 1
fi
if [ "$THRESHOLD" -lt 1 ] || [ "$THRESHOLD" -gt 100 ]; then
    echo "Ошибка: порог должен быть от 1 до 100, а получено: $THRESHOLD"
    exit 1
fi

if ! mountpoint -q "$LOGS_DIR"; then
    echo "Ошибка: $LOGS_DIR не смонтирован, логи пишутся на системный диск"
    exit 1
fi

echo "=== Проверка $LOGS_DIR, $(date '+%Y-%m-%d %H:%M:%S') ==="

df_line=$(df -P -k "$LOGS_DIR" | tail -n 1)
used_kb=$(echo "$df_line" | tr -s ' ' | cut -d ' ' -f 3)
free_kb=$(echo "$df_line" | tr -s ' ' | cut -d ' ' -f 4)

capacity_kb=$((used_kb + free_kb))

limit_kb=$((capacity_kb * THRESHOLD / 100))
folder_limit_kb=$((limit_kb / 3))
used_percent=$((used_kb * 100 / capacity_kb))

echo "Раздел: доступно под данные $capacity_kb КБ, занято $used_kb КБ ($used_percent%)"
echo "Общий лимит: $limit_kb КБ ($THRESHOLD%), лимит одной папки: $folder_limit_kb КБ"

if [ "$used_kb" -le "$limit_kb" ]; then
    echo "Порог не превышен, архивировать нечего"
    exit 0
fi

echo "Порог превышен, проверяю папки компонент"

archive_folder() {
    component="$1"
    dir="$LOGS_DIR/$component"

    folder_kb=$(du -s -k "$dir" | cut -f 1)
    target_kb=$((folder_limit_kb * TARGET_PERCENT / 100))
    need_to_free_kb=$((folder_kb - target_kb))

    log_count=0
    for file in "$dir"/*.log; do
        if [ -f "$file" ]; then
            log_count=$((log_count + 1))
        fi
    done

    files_to_archive=""
    freed_kb=0
    number=0
    for file in "$dir"/*.log; do
        if [ ! -f "$file" ]; then
            continue
        fi
        number=$((number + 1))
        if [ "$number" -eq "$log_count" ]; then
            break
        fi
        if [ "$freed_kb" -ge "$need_to_free_kb" ]; then
            break
        fi
        file_kb=$(du -k "$file" | cut -f 1)
        freed_kb=$((freed_kb + file_kb))
        files_to_archive="$files_to_archive $(basename "$file")"
    done

    if [ -z "$files_to_archive" ]; then
        echo "  $component: нечего архивировать (остался только текущий файл)"
        return
    fi

    if [ ! -d "$dir/archive" ]; then
        mkdir "$dir/archive"
    fi
    archive_name="${component}_archive_$(date '+%Y_%m_%d_%H%M%S').tar.gz"

    tar -czf "$dir/archive/$archive_name" -C "$dir" $files_to_archive
    if [ $? -ne 0 ]; then
        rm -f "$dir/archive/$archive_name"
        echo "  $component: ошибка tar, файлы не удалены"
        had_errors=1
        return
    fi

    archived_count=0
    for name in $files_to_archive; do
        rm "$dir/$name"
        archived_count=$((archived_count + 1))
    done

    new_folder_kb=$(du -s -k "$dir" | cut -f 1)
    echo "  $component: заархивировано файлов: $archived_count, архив archive/$archive_name"
    echo "  $component: было $folder_kb КБ, стало $new_folder_kb КБ"
}

for component in $COMPONENTS; do
    dir="$LOGS_DIR/$component"
    if [ ! -d "$dir" ]; then
        echo "  $component: папки нет, пропускаю"
        continue
    fi

    folder_kb=$(du -s -k "$dir" | cut -f 1)
    if [ "$folder_kb" -le "$folder_limit_kb" ]; then
        echo "  $component: $folder_kb КБ, в пределах лимита"
    else
        echo "  $component: $folder_kb КБ, лимит превышен"
        archive_folder "$component"
    fi
done

exit $had_errors
