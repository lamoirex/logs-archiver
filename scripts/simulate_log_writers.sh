#!/usr/bin/env bash
# Притворяется компонентами ИС и пишет их логи в /LOGS, чтобы проверить архиватор вживую.
set -euo pipefail

LOGS_DIR="${LOGS_DIR:-/LOGS}"
COMPONENTS="${COMPONENTS:-auth_service data_process_service system_event_handler_service}"
# Компоненты пишут с разной скоростью, чтобы за 1/3 вылезала только одна папка
RATES_KB="${RATES_KB:-600 200 100}"
INTERVAL="${INTERVAL:-1}"
ROTATE_SEC="${ROTATE_SEC:-20}"
STOP_AT="${STOP_AT:-95}"
DURATION="${DURATION:-0}"
BACKFILL_DAYS="${BACKFILL_DAYS:-0}"

log() { echo "$(date '+%F %T') simulate: $*"; }
err() { echo "$(date '+%F %T') simulate: ERROR: $*" >&2; }

usage() {
    cat <<EOF
Использование: simulate_log_writers.sh [--duration SEC] [--stop-at PCT] [--backfill DAYS] [--help]

Имитирует компоненты ИС: каждая пишет свой лог в LOGS_DIR/<компонента>/
с именем <компонента>_YYYY_MM_DD_<timestamp>.log и раз в ROTATE_SEC секунд
начинает новый файл. Остановка: Ctrl+C или по истечении --duration.

  --duration SEC   сколько секунд работать (0 — бесконечно)        [${DURATION}]
  --stop-at PCT    при заполнении >= PCT% запись приостанавливается  [${STOP_AT}]
  --backfill DAYS  перед стартом создать логи за DAYS прошлых дней   [${BACKFILL_DAYS}]

Переменные окружения:
  LOGS_DIR    корневая папка логов                [${LOGS_DIR}]
  COMPONENTS  компоненты через пробел             [${COMPONENTS}]
  RATES_KB    КБ за шаг для каждой компоненты     [${RATES_KB}]
  INTERVAL    длительность шага, сек              [${INTERVAL}]
  ROTATE_SEC  через сколько секунд новый файл     [${ROTATE_SEC}]
EOF
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --duration) DURATION="${2:-}"; shift 2 ;;
        --stop-at) STOP_AT="${2:-}"; shift 2 ;;
        --backfill) BACKFILL_DAYS="${2:-}"; shift 2 ;;
        *) err "неизвестный аргумент: $1"; usage >&2; exit 2 ;;
    esac
done

for v in DURATION STOP_AT BACKFILL_DAYS INTERVAL ROTATE_SEC; do
    if ! is_uint "${!v}"; then
        err "${v} должно быть целым неотрицательным числом, получено '${!v}'"
        exit 2
    fi
done

read -r -a comps <<< "$COMPONENTS"
read -r -a rates <<< "$RATES_KB"
if [[ ${#comps[@]} -ne ${#rates[@]} ]]; then
    err "количество COMPONENTS (${#comps[@]}) и RATES_KB (${#rates[@]}) не совпадает"
    exit 2
fi
for r in "${rates[@]}"; do
    is_uint "$r" || { err "RATES_KB содержит не число: '$r'"; exit 2; }
done

if [[ ! -d "$LOGS_DIR" ]]; then
    err "папка $LOGS_DIR не найдена (смонтирован ли раздел?)"
    exit 3
fi

for c in "${comps[@]}"; do
    mkdir -p "${LOGS_DIR}/${c}"
done

usage_pct() { df --output=pcent "$LOGS_DIR" | tail -n 1 | tr -dc '0-9'; }

# Собирает имя файла в формате из задания: компонента_YYYY_MM_DD_timestamp.log
log_name() {
    local comp=$1 ts=$2
    echo "${LOGS_DIR}/${comp}/${comp}_$(date -d "@${ts}" +%Y_%m_%d)_${ts}.log"
}

# Дописывает в файл примерно kb килобайт одинаковых строк лога
write_chunk() {
    local file=$1 comp=$2 kb=$3 ts=$4
    local line lines
    line="$(date -d "@${ts}" '+%F %T') [INFO] ${comp}: pid=$$ req=${RANDOM}${RANDOM} user=u${RANDOM} status=ok latency_ms=$((RANDOM % 500)) msg=request processed"
    lines=$(( kb * 1024 / (${#line} + 1) ))
    (( lines > 0 )) || lines=1
    head -n "$lines" < <(yes "$line") >> "$file"
}

# Создаёт логи за прошлые дни, чтобы не ждать, пока они накопятся
backfill() {
    local days=$1 now d i ts file kb
    now=$(date +%s)
    log "создаю логи за ${days} прошлых дней"
    for (( d = days; d >= 1; d-- )); do
        ts=$(( now - d * 86400 ))
        for i in "${!comps[@]}"; do
            if (( $(usage_pct) >= STOP_AT )); then
                log "заполнение $(usage_pct)% >= ${STOP_AT}%, предзаполнение остановлено"
                return 0
            fi
            file=$(log_name "${comps[$i]}" "$ts")
            kb=$(( rates[i] * 10 ))
            write_chunk "$file" "${comps[$i]}" "$kb" "$ts" || err "не удалось записать $file"
        done
    done
    log "предзаполнение готово, заполнение $(usage_pct)%"
}

trap 'echo; log "остановлен, заполнение $(usage_pct)%"; exit 0' INT TERM

if (( BACKFILL_DAYS > 0 )); then
    backfill "$BACKFILL_DAYS"
fi

declare -A cur_file=()
declare -A cur_start=()
start=$(date +%s)
tick=0
paused=0

log "старт: ${LOGS_DIR}, компоненты: ${COMPONENTS}, КБ за шаг: ${RATES_KB}, шаг ${INTERVAL}с, ротация ${ROTATE_SEC}с, пауза при ${STOP_AT}%"

# Главный цикл: если места мало, то ждём архиватор, иначе пишем и раз в ROTATE_SEC начинаем новый файл
while true; do
    now=$(date +%s)
    if (( DURATION > 0 && now - start >= DURATION )); then
        log "время вышло (${DURATION}с), заполнение $(usage_pct)%"
        break
    fi

    pct=$(usage_pct)
    if (( pct >= STOP_AT )); then
        if (( paused == 0 )); then
            log "заполнение ${pct}% >= ${STOP_AT}%, запись приостановлена до освобождения места"
            paused=1
        fi
        sleep "$INTERVAL"
        continue
    fi
    if (( paused == 1 )); then
        log "место освободилось (${pct}%), продолжаю запись"
        paused=0
    fi

    for i in "${!comps[@]}"; do
        c=${comps[$i]}
        if [[ -z "${cur_file[$c]:-}" ]] || (( now - cur_start[$c] >= ROTATE_SEC )); then
            cur_file[$c]=$(log_name "$c" "$now")
            cur_start[$c]=$now
        fi
        write_chunk "${cur_file[$c]}" "$c" "${rates[$i]}" "$now" || err "не удалось записать ${cur_file[$c]}"
    done

    tick=$(( tick + 1 ))
    if (( tick % 10 == 0 )); then
        log "заполнение ${pct}%"
    fi
    sleep "$INTERVAL"
done
