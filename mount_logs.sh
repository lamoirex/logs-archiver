#!/bin/bash

LABEL="LOGS"
MOUNT_DIR="/LOGS"
COMPONENTS="auth_service data_process_service system_event_handler_service"

if mountpoint -q "$MOUNT_DIR"; then
    echo "$MOUNT_DIR уже смонтирован, ничего не делаю"
    exit 0
fi

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

if [ ! -d "$MOUNT_DIR" ]; then
    mkdir "$MOUNT_DIR"
fi

mount "$device" "$MOUNT_DIR"
if [ $? -ne 0 ]; then
    echo "Ошибка: не удалось смонтировать $device в $MOUNT_DIR"
    exit 1
fi
echo "Раздел $device смонтирован в $MOUNT_DIR"

for component in $COMPONENTS; do
    if [ ! -d "$MOUNT_DIR/$component" ]; then
        mkdir "$MOUNT_DIR/$component"
        echo "Создана папка $MOUNT_DIR/$component"
    fi
done

exit 0
