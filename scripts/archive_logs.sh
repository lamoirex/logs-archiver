#!/bin/bash
# Следит, чтобы раздел /LOGS не переполнился.
#
# Если раздел заполнен больше чем на THRESHOLD процентов, общий лимит
# делится на 3 компоненты. В папках, которые заняли больше своей трети,
# старые .log файлы упаковываются в архив .tar.gz (в подпапку archive),
# а сами файлы удаляются.
#
# Запуск: archive_logs.sh [папка_с_логами] [порог_в_процентах]
# По умолчанию: /LOGS и 90.
# Коды выхода: 0 - всё хорошо, 1 - ошибка.

LOGS_DIR="/LOGS"
THRESHOLD=90
COMPONENTS="auth_service data_process_service system_event_handler_service"

# Папку чистим не ровно до лимита, а до 80% от него.
# Иначе после архивации папка будет у самой границы и скрипт
# снова сработает при следующем запуске.
TARGET_PERCENT=80

# ---------- 1. Аргументы ----------

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

# Если раздел не смонтирован, то /LOGS это просто пустая папка на системном диске.
# Проверять её бессмысленно, лучше сразу сообщить об ошибке.
if ! mountpoint -q "$LOGS_DIR"; then
    echo "Ошибка: $LOGS_DIR не смонтирован, раздел для логов не подключён"
    exit 1
fi

# Порог должен быть целым числом от 1 до 100
if ! echo "$THRESHOLD" | grep -q '^[0-9][0-9]*$'; then
    echo "Ошибка: порог должен быть целым числом, а получено: $THRESHOLD"
    exit 1
fi
# Убираем ведущие нули: 090 -> 90, иначе bash считает число восьмеричным
THRESHOLD=$((10#$THRESHOLD))
if [ "$THRESHOLD" -lt 1 ] || [ "$THRESHOLD" -gt 100 ]; then
    echo "Ошибка: порог должен быть от 1 до 100, а получено: $THRESHOLD"
    exit 1
fi

echo "=== Проверка $LOGS_DIR, $(date '+%Y-%m-%d %H:%M:%S') ==="

# ---------- 2. Сколько занято на разделе ----------

# df -P печатает информацию о разделе в одну строку, -k - размеры в килобайтах.
# Вторая строка вывода: устройство, размер, занято, свободно, процент, точка монтирования
df_line=$(df -P -k "$LOGS_DIR" | tail -n 1)
# tr -s ' ' склеивает подряд идущие пробелы в один, чтобы cut мог взять нужную колонку
used_kb=$(echo "$df_line" | tr -s ' ' | cut -d ' ' -f 3)
free_kb=$(echo "$df_line" | tr -s ' ' | cut -d ' ' -f 4)

# ext4 оставляет около 5% места только для root, обычным программам оно недоступно.
# Поэтому считаем размер как "занято + свободно", ровно так же считает процент df.
total_kb=$((used_kb + free_kb))

limit_kb=$((total_kb * THRESHOLD / 100))
folder_limit_kb=$((limit_kb / 3))
used_percent=$((used_kb * 100 / total_kb))

echo "Раздел: доступно $total_kb КБ, занято $used_kb КБ ($used_percent%)"
echo "Общий лимит: $limit_kb КБ ($THRESHOLD%), лимит одной папки: $folder_limit_kb КБ"

if [ "$used_kb" -le "$limit_kb" ]; then
    echo "Порог не превышен, архивировать нечего"
    exit 0
fi

echo "Порог превышен, проверяю папки компонент"

# ---------- 3. Архивация одной папки ----------

# Аргумент: имя компоненты (имя её папки)
archive_folder() {
    component="$1"
    dir="$LOGS_DIR/$component"

    folder_kb=$(du -s -k "$dir" | cut -f 1)
    target_kb=$((folder_limit_kb * TARGET_PERCENT / 100))
    need_to_free_kb=$((folder_kb - target_kb))

    # Считаем .log файлы: самый новый трогать нельзя, в него сейчас пишет компонента
    log_count=0
    for file in "$dir"/*.log; do
        if [ -f "$file" ]; then
            log_count=$((log_count + 1))
        fi
    done

    # Набираем старые файлы, пока не освободим нужный объём.
    # В имени файла дата и время создания (YYYY_MM_DD_timestamp), поэтому
    # bash выдаёт файлы по алфавиту, а это и есть порядок от старых к новым.
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

    # -c создать архив, -z сжать через gzip, -f имя архива,
    # -C перед упаковкой зайти в папку, чтобы в архиве лежали только имена файлов
    tar -czf "$dir/archive/$archive_name" -C "$dir" $files_to_archive
    if [ $? -ne 0 ]; then
        # Недописанный архив никому не нужен и только занимает место
        rm -f "$dir/archive/$archive_name"
        echo "  $component: ошибка tar, битый архив удалён, файлы не тронуты"
        had_error=1
        return
    fi

    # Удаляем файлы только после того, как архив успешно создан
    archived_count=0
    for name in $files_to_archive; do
        rm "$dir/$name"
        archived_count=$((archived_count + 1))
    done

    new_folder_kb=$(du -s -k "$dir" | cut -f 1)
    echo "  $component: заархивировано файлов: $archived_count, архив archive/$archive_name"
    echo "  $component: было $folder_kb КБ, стало $new_folder_kb КБ"
}

# ---------- 4. Проверяем каждую папку ----------

# Станет 1, если хотя бы в одной папке архивация не удалась
had_error=0

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

# Код 1 нужен, чтобы cron и systemd узнали об ошибке
if [ "$had_error" -eq 1 ]; then
    exit 1
fi
exit 0
