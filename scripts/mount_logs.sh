#!/bin/bash
# Монтирует раздел с меткой LOGS в папку /LOGS.
# Запускается при загрузке системы службой mount-logs.service.
# Метка ставится один раз при форматировании: mkfs.ext4 -L LOGS /dev/sdb1

LABEL="LOGS"
MOUNT_DIR="/LOGS"
COMPONENTS="auth_service data_process_service system_event_handler_service"

# 1. Если раздел уже смонтирован, второй раз монтировать не нужно
if mountpoint -q "$MOUNT_DIR"; then
    echo "$MOUNT_DIR уже смонтирован, ничего не делаю"
    exit 0
fi

# 2. Ищем раздел по метке. Флешка при загрузке может появиться не сразу,
#    поэтому пробуем 10 раз с паузой в 1 секунду
device=""
attempt=1
while [ $attempt -le 10 ]; do
    device=$(blkid -L "$LABEL")
    if [ -n "$device" ]; then
        break
    fi
    echo "Раздел с меткой $LABEL пока не найден, попытка $attempt из 10"
    sleep 1
    attempt=$((attempt + 1))
done

if [ -z "$device" ]; then
    echo "Ошибка: раздел с меткой $LABEL не найден"
    exit 1
fi

# 3. Создаём точку монтирования, если её ещё нет
if [ ! -d "$MOUNT_DIR" ]; then
    mkdir "$MOUNT_DIR"
fi

# 4. Монтируем
mount "$device" "$MOUNT_DIR"
if [ $? -ne 0 ]; then
    echo "Ошибка: не удалось смонтировать $device в $MOUNT_DIR"
    exit 1
fi
echo "Раздел $device смонтирован в $MOUNT_DIR"

# 5. Папки компонент: на свежем разделе их ещё нет
for component in $COMPONENTS; do
    if [ ! -d "$MOUNT_DIR/$component" ]; then
        mkdir "$MOUNT_DIR/$component"
        echo "Создана папка $MOUNT_DIR/$component"
    fi
done

exit 0
