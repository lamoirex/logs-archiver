#!/usr/bin/env bash
# Монтирует раздел под логи в /LOGS и создаёт папки компонент.
# Можно гонять сколько угодно раз: если уже смонтировано, то просто выходим.
set -euo pipefail

# Всё настраивается через переменные окружения, а ниже указаны значения по умолчанию.
# IMG_FILE может быть файлом-образом, устройством (/dev/sdb1) или UUID=... для флешки.
IMG_FILE="${IMG_FILE:-/opt/logs.img}"
MOUNT_POINT="${MOUNT_POINT:-/LOGS}"
FS_TYPE="${FS_TYPE:-ext4}"
SUBDIRS="${SUBDIRS:-auth_service data_process_service system_event_handler_service}"

log() { echo "mount_logs: $*"; }
err() { echo "mount_logs: ERROR: $*" >&2; }

# Справка по --help
usage() {
    cat <<EOF
Использование: mount_logs.sh [--help]

Монтирует IMG_FILE в MOUNT_POINT и создаёт подпапки компонент.

Переменные окружения:
  IMG_FILE     источник (файл-образ, /dev/..., UUID=..., LABEL=...)  [${IMG_FILE}]
  MOUNT_POINT  точка монтирования                                    [${MOUNT_POINT}]
  FS_TYPE      тип файловой системы                                  [${FS_TYPE}]
  SUBDIRS      подпапки компонент                                    [${SUBDIRS}]

Коды возврата: 0 — смонтировано (или уже было), 1 — ошибка.
EOF
}

# Создаёт папки компонент внутри /LOGS, если их ещё нет
create_subdirs() {
    local dirs d
    read -r -a dirs <<< "$SUBDIRS"
    for d in "${dirs[@]}"; do
        if ! mkdir -p "${MOUNT_POINT}/${d}"; then
            err "не удалось создать ${MOUNT_POINT}/${d}"
            return 1
        fi
    done
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) err "неизвестный аргумент: $1"; usage >&2; exit 1 ;;
esac

# Без root ни mount, ни mkdir в / не сработают
if [[ ${EUID} -ne 0 ]]; then
    err "нужны права root (запустите через sudo)"
    exit 1
fi

if ! mkdir -p "${MOUNT_POINT}"; then
    err "не удалось создать точку монтирования ${MOUNT_POINT}"
    exit 1
fi

# Если уже смонтировано (например, вторым запуском), то ничего не трогаем
if mountpoint -q "${MOUNT_POINT}"; then
    log "${MOUNT_POINT} уже смонтирован ($(findmnt -n -o SOURCE "${MOUNT_POINT}")), пропускаю"
    create_subdirs || exit 1
    exit 0
fi

# Файл монтируем через loop, а устройство или UUID, то как обычный диск
if [[ "${IMG_FILE}" == UUID=* || "${IMG_FILE}" == LABEL=* ]]; then
    mount_opts="defaults"
elif [[ -b "${IMG_FILE}" ]]; then
    mount_opts="defaults"
elif [[ -f "${IMG_FILE}" ]]; then
    mount_opts="loop"
else
    err "источник не найден: ${IMG_FILE}"
    exit 1
fi

log "монтирую ${IMG_FILE} -> ${MOUNT_POINT} (type=${FS_TYPE}, opts=${mount_opts})"
if ! mount -t "${FS_TYPE}" -o "${mount_opts}" "${IMG_FILE}" "${MOUNT_POINT}"; then
    err "mount завершился с ошибкой"
    exit 1
fi

# На всякий случай убеждаемся, что mount реально сработал
if ! mountpoint -q "${MOUNT_POINT}"; then
    err "после mount ${MOUNT_POINT} не является точкой монтирования"
    exit 1
fi

create_subdirs || exit 1

log "готово: $(df -h --output=source,size,used,avail,pcent "${MOUNT_POINT}" | tail -n 1)"
exit 0
