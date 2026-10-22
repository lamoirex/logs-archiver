# logs-archiver

Раздел /LOGS для логов трёх компонент ИС: монтирование при загрузке и
архивация старых логов, чтобы раздел не переполнялся.

## Файлы

- `mount_logs.sh` - монтирует раздел с меткой LOGS в /LOGS и создаёт папки компонент
- `logs-mount.service` - служба systemd, запускает mount_logs.sh при загрузке системы
- `archive_logs.sh` - если раздел заполнен больше чем на 90%, архивирует старые логи
  в папках компонент, которые заняли больше 1/3 лимита
- `test_archive_logs.sh` - автотесты для archive_logs.sh (8 сценариев)

## 1. Подготовка раздела (один раз)

Флешка или второй диск, например /dev/sdb. Посмотреть устройства: `lsblk`.

```
sudo fdisk /dev/sdb              # создать раздел: n, p, 1, Enter, Enter, w
sudo mkfs.ext4 -L LOGS /dev/sdb1 # отформатировать в ext4 с меткой LOGS
```

## 2. Монтирование при загрузке

```
sudo cp mount_logs.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/mount_logs.sh
sudo cp logs-mount.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable logs-mount.service
sudo systemctl start logs-mount.service
systemctl status logs-mount.service
```

Проверка: `df -h /LOGS`, затем `sudo reboot` и снова `df -h /LOGS`.

## 3. Архивация каждые 5 минут

```
sudo cp archive_logs.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/archive_logs.sh
echo "*/5 * * * * root /usr/local/bin/archive_logs.sh >> /var/log/archive_logs.log 2>&1" | sudo tee /etc/cron.d/archive_logs
```

Запуск вручную: `sudo archive_logs.sh` (папка /LOGS, порог 90%)
или `sudo archive_logs.sh /LOGS 85`.

- Проценты считаются так же, как в `df -h`: без резерва ext4 для root.
- Архивы: `/LOGS/<компонента>/archive/<компонента>_archive_<дата>.tar.gz`.
- Самый новый лог компоненты не архивируется: в него идёт запись.
- Коды выхода: 0 - всё хорошо; 1 - неверные аргументы, /LOGS не смонтирован
  или tar не смог создать архив.

## 4. Тесты

```
sudo bash test_archive_logs.sh
```

Тест сам создаёт раздел на 100 МБ (файл-образ с ext4), прогоняет 8 сценариев
и за собой всё убирает. В конце строка "Пройдено тестов: 8 из 8".

Репозиторий лучше клонировать прямо в Linux: при клонировании в Windows git
может заменить окончания строк, и bash не запустит скрипты.
