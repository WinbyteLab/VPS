## Что делает скрипт

| № | Категория | Проверки | Критичность |
| :--- | :--- | :--- | :--- |
| **1** | Окружение | PowerShell 5.1+, права, ОС | ℹ️ Инфо |
| **2** | Системный прокси | Реестр Windows: `ProxyEnable`, `ProxyServer`, порт | ⚠️ WARN если выключен |
| **3** | Переменные окружения | `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` (User + Process) | ⚠️ WARN если нет |
| **4** | Локальный прокси | TCP-доступность `127.0.0.1:10809` (или своих портов) | ❌ FAIL если закрыт |
| **5** | Внешний IP | Через прокси → сверка с `-VPSIP` | ❌ FAIL при несовпадении |
| **6** | Геолокация | Страна, город, org через `ipinfo.io` | ❌ FAIL для RU/BY/IR/KP |
| **7** | DNS | Системные DNS (не российские), резолвинг `api.anthropic.com` | ⚠️ WARN |
| **8** | WebRTC | Инструкция к ручной проверке | ℹ️ Инфо |
| **9** | Claude Code | `~/.claude/settings.json` → `env.HTTPS_PROXY` | ⚠️ WARN |
| **10** | VS Code | `Code/User/settings.json` → `http.proxy` | ⚠️ WARN |
| **11** | Cursor | `http.proxy` + **`disableHttp2`** (критично!) | ❌ FAIL если нет `disableHttp2` |
| **12** | Часовой пояс | Соответствие `-ExpectedCountry` | ⚠️ WARN |
| **13** | Локаль | `Get-UICulture` / `Get-Culture` (не `ru-*`) | ⚠️ WARN |
| **14** | Сеть | `api.anthropic.com`, `claude.ai`, TCP 443, ping до VPS | ❌ FAIL при недоступности |

## Использование

```powershell
# 1. Простая проверка (порт по умолчанию 10809)
.\verify-leaks.ps1

# 2. Полная проверка с VPS IP и ожидаемой страной
.\verify-leaks.ps1 -VPSIP 203.0.113.42 -ExpectedCountry DE

# 3. Проверить несколько портов
.\verify-leaks.ps1 -ProxyPort "10809,10808,8080,7890"

# 4. JSON для автоматизации
.\verify-leaks.ps1 -VPSIP 203.0.113.42 -ExpectedCountry US -Json | Out-File report.json

# 5. Только локальные конфиги (быстро, без сети)
.\verify-leaks.ps1 -SkipNetwork

# 6. Только сетевые проверки (без конфигов инструментов)
.\verify-leaks.ps1 -SkipConfig -VPSIP 203.0.113.42

# 7. С подробным выводом
.\verify-leaks.ps1 -VPSIP 203.0.113.42 -ExpectedCountry DE -Verbose
```

## Обход политики выполнения (если PowerShell блокирует)

```powershell
# Временно разрешить запуск скриптов в текущей сессии
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\verify-leaks.ps1

# Или запустить в обход
powershell -ExecutionPolicy Bypass -File .\verify-leaks.ps1
```

## Exit codes

| Код | Значение |
| :---: | :--- |
| `0` | Все проверки пройдены |
| `1` | Есть предупреждения (WARN) — просмотрите |
| `2` | Критические проблемы (FAIL) — исправьте до входа в Claude |

## Соответствие шагам из `pc-setup.md`

| Шаг `pc-setup.md` | Покрытие в `verify-leaks.ps1` |
| :--- | :--- |
| 2.1.5 HTTP-прокси на 10809 | Секция 4 (TCP-порт) |
| 2.1.6 Remote DNS | Секция 7 (DNS) |
| 2.2.4 Timezone = Auto | Секция 12 (часовой пояс) |
| 2.2.4 Language = Auto | Секция 13 (локаль) |
| 2.2.5 Проверка IP | Секция 5 (внешний IP) |
| 2.2.5 Проверка WebRTC | Секция 8 (инструкция) |
| 2.3 Переменные окружения | Секция 3 |
| 2.4 Проверка утечек | Секции 5–8 |

## Что скрипт **не** проверяет (и почему)

| Что | Почему | Как проверить |
| :--- | :--- | :--- |
| **WebRTC** | Требуется браузер (JS API) | `browserleaks.com/webrtc` в Dolphin |
| **Canvas/WebGL fingerprint** | Требуется браузер | `browserleaks.com/canvas` |
| **TLS fingerprint** | Требуется клиент с TLS-инспекцией | `tls.peet.ws/api/all` |
| **DNS-утечки через прокси** | `Resolve-DnsName` идёт мимо прокси | `ipleak.net` в Dolphin |
| **Fraud Score** | Нет публичного API у Scamalytics | `scamalytics.com/ip/<IP>` |
| **AbuseIPDB** | Требуется API-ключ | `check-ip.sh` на VPS |

Для полной проверки используйте **совместно** :
- `verify-leaks.ps1` — на ПК (локальные конфиги + внешний IP через прокси)
- `check-ip.sh` — на VPS (Fraud Score + DNSBL + AbuseIPDB)
- Ручные проверки в Dolphin (WebRTC, DNS, fingerprint)
