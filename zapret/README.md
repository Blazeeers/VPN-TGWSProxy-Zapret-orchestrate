# zapret: DPI-обход и автотюн

Каталог со скриптами обхода блокировок Discord/YouTube (zapret/nfqws) и
автоматического подбора стратегии под текущую сеть.

Полная документация — [../docs/zapret.md](../docs/zapret.md).

## Файлы

| Файл | Запуск | Назначение |
|---|---|---|
| `zapret-autotune` | от root (сервис) | подбор/применение стратегии, кэш по сетям, откат на VPN |
| `zapret-autotune-install.sh` | `sudo bash` | установка сервиса, таймера, NM-хука |
| `zapret-blockcheck.sh` | `sudo bash` | глубокий перебор штатным `blockcheck.sh` |
| `zapret-setup.sh` | `sudo bash` | базовый конфиг zapret + исключение серверов omavpn |
| `zapret-hostlist.sh` | `sudo bash` | режим hostlist + списки Discord/YouTube |
| `zapret-strategy.sh` | `sudo bash` | ручное переключение/перебор пресетов |

## Порядок установки

```bash
yay -S zapret-git
sudo bash zapret-setup.sh
sudo bash zapret-hostlist.sh
sudo bash zapret-autotune-install.sh
```

Управление:

```bash
sudo zapret-autotune run|rescan|tune-wan
zapret-autotune show
```
