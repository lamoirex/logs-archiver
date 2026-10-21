# Лабораторная: раздел /LOGS и архивация логов

## Файлы

- `scripts/mount_logs.sh` - монтирует раздел с меткой LOGS в /LOGS и создаёт папки компонент
- `systemd/mount-logs.service` - служба systemd, запускает mount_logs.sh при загрузке
- `scripts/archive_logs.sh` - проверяет заполнение /LOGS и архивирует старые логи
- `tests/run_archiver_tests.sh` - автотесты для archive_logs.sh (6 сценариев)

## 1. Подготовка раздела (один раз)

Флешка или второй диск, например /dev/sdb. Посмотреть устройства: `lsblk`.

```
sudo fdisk /dev/sdb              # создать раздел: n, p, 1, Enter, Enter, w
sudo mkfs.ext4 -L LOGS /dev/sdb1 # отформатировать и поставить метку LOGS
```

## 2. Монтирование при запуске системы

```
sudo cp scripts/mount_logs.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/mount_logs.sh
sudo cp systemd/mount-logs.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable mount-logs.service   # запускать при загрузке
sudo systemctl start mount-logs.service    # запустить сейчас
systemctl status mount-logs.service
```

Проверка после перезагрузки: `df -h /LOGS`.

## 3. Архивация по расписанию (каждые 5 минут)

```
sudo cp scripts/archive_logs.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/archive_logs.sh
echo "*/5 * * * * root /usr/local/bin/archive_logs.sh >> /var/log/archive_logs.log 2>&1" | sudo tee /etc/cron.d/archive_logs
```

Запуск вручную: `sudo archive_logs.sh` (по умолчанию /LOGS и порог 90%),
или с параметрами: `sudo archive_logs.sh /LOGS 85`.

Архивы складываются в подпапку `archive` каждой компоненты, например
`/LOGS/auth_service/archive/auth_service_archive_2026_10_21_192233.tar.gz`.

## 4. Тесты

```
sudo bash tests/run_archiver_tests.sh
```

Тест сам создаёт раздел на 100 МБ (файл-образ с ext4), прогоняет 6 сценариев
и за собой всё убирает. В конце строка "Пройдено тестов: 6 из 6".
