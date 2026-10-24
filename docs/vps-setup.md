# 🖥️ VPS Setup — расширенное руководство

> **Часть 1 из серии руководств по построению стабильной инфраструктуры доступа к Claude AI.**
> Полное пошаговое руководство по выбору, подготовке и настройке VPS-сервера в роли прокси-шлюза (VLESS + Reality).

[![Part](https://img.shields.io/badge/part-1%20of%203-blue)]()
[![Level](https://img.shields.io/badge/level-intermediate--advanced-orange)]()
[![Time](https://img.shields.io/badge/time-60--90%20min-yellow)]()

---

## ⚠️ Дисклеймер

> Руководство носит исключительно технический и образовательный характер. Автор не гарантирует отсутствие блокировок со стороны Anthropic и не призывает к нарушению Terms of Service. Используйте на свой риск. Соблюдайте законодательство своей страны.

---

## 📖 Оглавление

- [0. Предварительные требования](#0-предварительные-требования)
- [1.1. Выбор конфигурации и провайдера](#11-выбор-конфигурации-и-провайдера)
- [1.2. Проверка «чистоты» IP-адреса](#12-проверка-чистоты-ip-адреса)
- [1.3. Базовая подготовка и харденинг системы](#13-базовая-подготовка-и-харденинг-системы)
- [1.4. Установка 3x-ui](#14-установка-3x-ui)
- [1.5. Создание inbound VLESS + Reality](#15-создание-inbound-vless--reality)
- [1.6. Опционально: WARP для маскировки исходящего трафика](#16-опционально-warp-для-маскировки-исходящего-трафика)
- [1.7. Мониторинг, обслуживание и бэкапы](#17-мониторинг-обслуживание-и-бэкапы)
- [1.8. Troubleshooting](#18-troubleshooting)
- [🔒 Финальный чек-лист безопасности](#-финальный-чек-лист-безопасности)

---

## 0. Предварительные требования

### Что понадобится **до** начала работы

| Компонент | Назначение |
| :--- | :--- |
| **ПК с SSH-клиентом** | Windows 10/11 (встроенный `ssh`), macOS (встроенный), Linux (`openssh-client`) |
| **Сгенерированная SSH-пара ключей** | `ssh-keygen -t ed25519 -C "claude-vps"` |
| **Банковская карта** для оплаты VPS | Иностранная виртуальная карта или карта поддерживаемого банка |
| **Менеджер паролей** | Bitwarden, KeePassXC — для хранения паролей панели и ключей |
| **Стабильное интернет-соединение** | Любое |

### Что мы **не** будем делать

- ❌ Устанавливать «всё в одном» (VPN + Claude + браузер) — это создаёт единую точку отказа.
- ❌ Использовать бесплатные VPS-провайдеры — их IP-диапазоны почти всегда в чёрных списках.
- ❌ Открывать панель 3x-ui в публичный интернет без защиты.
- ❌ Логировать чувствительные данные на сервере.

### Ожидаемое время

| Этап | Время |
| :--- | :--- |
| Выбор и аренда VPS | 10–15 мин |
| Проверка IP | 5 мин |
| Харденинг SSH + firewall | 20–30 мин |
| Установка 3x-ui | 5–10 мин |
| Настройка VLESS + Reality | 10–15 мин |
| Проверка и тесты | 10 мин |
| **Итого** | **~60–90 мин** |

---

## 1.1. Выбор конфигурации и провайдера

### 1.1.1. Требования к конфигурации

Трафик к Claude — это HTTPS-запросы и SSE-стриминг ответов. Нагрузка на CPU минимальна, пропускная способность — низкая (запросы текстовые, ответы — тоже).

| Параметр | Минимум | Рекомендуется | Зачем |
| :--- | :--- | :--- | :--- |
| **vCPU** | 1 | 1 | Xray однопоточен по своей природе для одного подключения |
| **RAM** | 1 GB | 2 GB | Запас под WARP, кеш, обновления |
| **Диск** | 20 GB SSD | 30 GB NVMe | Логи, обновления, snapshots |
| **Трафик** | 500 GB/мес | 1 TB/мес | Claude Code и Cursor генерируют умеренный трафик |
| **IPv4** | **Обязателен, статический** | — | Anthropic/CDN не всегда имеют AAAA-записи |
| **IPv6** | Опционально | — | Не критично |
| **Виртуализация** | KVM | KVM | OpenVZ/LXC может не поддерживать нужные sysctl и TUN |

> ❗ **Важно:** избегайте OpenVZ и LXC — они не позволяют менять ядерные параметры (`sysctl`), нужные для TUN-режима и некоторых оптимизаций. Только **KVM**.

### 1.1.2. Требования к локации

Локация — **критический** параметр. Выбирайте страну, где:

1. Anthropic официально предоставляет сервис.
2. IP-диапазоны провайдера имеют **низкий** Fraud Score (проверим на шаге 1.2).
3. Нет массовых блокировок со стороны Anthropic.

**Рекомендуемые локации:**

| Страна | Плюсы | Минусы |
| :--- | :--- | :--- |
| 🇺🇸 **США** | Anthropic — американская компания, наименьший риск | Дороже, выше latency из РФ |
| 🇩🇪 **Германия** | Хорошая репутация IP, дешевле | — |
| 🇳🇱 **Нидерланды** | Отличная связность, много провайдеров | Некоторые диапазоны «засвечены» |
| 🇬🇧 **Великобритания** | Официально поддерживается | Дороже |
| 🇫🇮 **Финляндия** | Близко к РФ, низкий latency | Меньше провайдеров |

> ❌ **Избегайте:** страны с высокой долей abuse-трафика (некоторые хостинги в Восточной Европе, Юго-Восточной Азии), страны под санкциями, «серые» локации.

### 1.1.3. Требования к провайдеру

| Критерий | Почему важно |
| :--- | :--- |
| **Возможность пересоздать сервер с новым IP** | Критично для шага 1.2 — если IP «грязный», нужен новый |
| **KVM-виртуализация** | См. выше |
| **Статический IPv4 включён в тариф** | Не все провайдеры дают статический IP по умолчанию |
| **API или быстрая панель** | Удобство управления |
| **Приемлемые условия оплаты** | Работа с картами, криптовалютой, PayPal |
| **Репутация провайдера** | Избегайте «однодневок» — потеряете данные при блокировке |

**Категории провайдеров:**

- **Крупные облака** (DigitalOcean, Vultr, Linode, Hetzner): стабильны, но IP-диапазоны хорошо известны антифрод-системам. Fraud Score может быть средним.
- **Средние VPS-провайдеры** (BuyVM, RackNerd, HostHatch, Contabo): лучший баланс, часто «чистые» IP.
- **Нишевые провайдеры** для обхода блокировок (VMiss, DMIT, BandwagonHost): оптимизированы под эти задачи, но дороже.

> 💡 **Совет:** для первого раза возьмите **Hetzner** (Германия/Финляндия) или **RackNerd** (США) — приемлемая цена, возможность пересоздать, стабильные IP.

### 1.1.4. Пошаговый процесс аренды

1. Зарегистрируйтесь у выбранного провайдера.
2. Выберите:
   - **Локацию:** согласно таблице выше.
   - **ОС:** **Ubuntu 22.04 LTS** или **Debian 12** (наиболее совместимы с 3x-ui).
   - **Конфигурацию:** 1 vCPU / 1–2 GB RAM / 20–30 GB SSD.
3. Оплатите (минимум на 1 месяц, лучше — на 3 для стабильности).
4. Дождитесь выдачи IP и root-пароля (или SSH-ключа) на email/в панели.
5. **Не устанавливайте ничего** — сначала шаг 1.2.

---

## 1.2. Проверка «чистоты» IP-адреса

> 🚨 **Это самый важный шаг всего руководства.** Установка ПО на «грязный» IP — потеря времени. Всегда проверяйте IP **до** установки.

### 1.2.1. Проверка Fraud Score

Откройте [`scamalytics.com`](https://scamalytics.com), введите IP вашего VPS.

| Fraud Score | Интерпретация | Действие |
| :--- | :--- | :--- |
| **0–30** | ✅ Низкий риск | Продолжайте |
| **30–74** | ⚠️ Средний риск | Допустимо, но мониторьте; при росте — пересоздайте |
| **75–100** | ❌ Высокий риск | **Немедленно пересоздайте сервер** |

### 1.2.2. Дополнительные проверки

**Тип IP** — [`ipinfo.io`](https://ipinfo.io):

```bash
curl -s https://ipinfo.io/$(curl -s ifconfig.me) | jq
```

Ожидаемый результат:

```json
{
  "ip": "1.2.3.4",
  "city": "Frankfurt",
  "region": "Hesse",
  "country": "DE",
  "org": "AS24940 Hetzner Online GmbH",
  "timezone": "Europe/Berlin"
}
```

> ✅ Тип `hosting` / `datacenter` — **нормально**. Anthropic работает с облачными провайдерами, IP дата-центра не является триггером сам по себе.
>
> ❌ Если IP числится как `tor`, `proxy`, `vpn` — **сразу пересоздавайте**.

**DNSBL** — [`multirbl.valli.org`](https://multirbl.valli.org):

- Введите IP, нажмите «Lookup».
- IP не должен появляться в **ни одной** значимой чёрной базе (Spamhaus, Barracuda, SORBS).

**Проверка на «засвеченность» через AbuseIPDB** — [`abuseipdb.com`](https://abuseipdb.com):

- Confidence of Abuse должен быть **< 25%**.
- Количество жалоб — **0** или близко к 0.

### 1.2.3. Что делать, если IP «грязный»

**Вариант A — пересоздать сервер.** В панели провайдера:

- DigitalOcean: `Destroy` → создать новый Drop.
- Hetzner: `Rebuild` (не всегда меняет IP) или удалить и создать заново.
- Vultr: `Server Destroy` → новый.

> ⚠️ Некоторые провайдеры выдают IP из **пула** — при пересоздании можно получить тот же IP. В таком случае повторите 2–3 раза или смените локацию.

**Вариант B — сменить провайдера.** Если 3 попытки подряд дают «грязный» IP — провайдер работает с плохими диапазонами, меняйте.

**Вариант C (не рекомендуется)** — «отмыть» IP. Долго, дорого, без гарантий. Лучше пересоздать.

### 1.2.4. Зафиксируйте результат

Сохраните в менеджере паролей:

```
IP: <IP_VPS>
Провайдер: <название>
Дата аренды: <дата>
Fraud Score на момент аренды: <число>
AbuseIPDB confidence: <число>
```

Это понадобится на шаге 1.7 для мониторинга.

---

## 1.3. Базовая подготовка и харденинг системы

> 🎯 **Цель:** превратить свежесозданный VPS в защищённую систему, готовую к установке 3x-ui. Без этого шага сервер уязвим к брутфорсу и атакам в течение **часов** после создания.

### 1.3.1. Первое подключение

```bash
# С вашего ПК
ssh root@<IP_VPS>
```

Если провайдер выдал SSH-ключ вместо пароля:

```bash
ssh -i ~/.ssh/<ваш_ключ> root@<IP_VPS>
```

При первом подключении подтвердите fingerprint (`yes`).

### 1.3.2. Обновление системы

```bash
apt update
apt upgrade -y
apt autoremove -y
apt autoclean
```

> ⚠️ Если после обновления требуется перезагрузка — выполните `reboot` и подождите 30 секунд.

### 1.3.3. Настройка часового пояса

**Критически важно** для консистентности: часовой пояс VPS должен совпадать с страной IP.

```bash
# Пример для Германии
timedatectl set-timezone Europe/Berlin

# Проверка
timedatectl
```

Для США (например, Нью-Йорк): `timedatectl set-timezone America/New_York`.
Для Великобритании: `Europe/London`. Для Нидерландов: `Europe/Amsterdam`.

### 1.3.4. Создание отдельного пользователя

Работа под `root` — плохая практика. Создадим пользователя `pilot`:

```bash
useradd -m -s /bin/bash pilot
passwd pilot                    # задайте надёжный пароль
usermod -aG sudo pilot
```

### 1.3.5. Настройка SSH-ключей

**На вашем ПК** (если ещё нет ключа):

```bash
ssh-keygen -t ed25519 -C "claude-vps-$(date +%Y-%m)"
# Сохраните в ~/.ssh/id_ed25519_claude
```

**Скопируйте публичный ключ на сервер:**

```bash
# С вашего ПК
ssh-copy-id -i ~/.ssh/id_ed25519_claude.pub pilot@<IP_VPS>
```

**Проверьте вход по ключу** (не закрывая текущую сессию!):

```bash
# Откройте НОВЫЙ терминал
ssh -i ~/.ssh/id_ed25519_claude pilot@<IP_VPS>
sudo whoami  # должно вернуть: root
```

> 🚨 **Не продолжайте** , пока не убедитесь, что вход по ключу работает. Иначе после отключения пароля потеряете доступ.

### 1.3.6. Харденинг SSH

Отредактируйте `/etc/ssh/sshd_config`:

```bash
sudo nano /etc/ssh/sshd_config
```

Приведите ключевые параметры к виду:

```ini
# Аутентификация
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes

# Порт (нестандартный — снижает шум от ботов, но не заменяет харденинг)
Port 1337

# Таймауты и keepalive
ClientAliveInterval 60
ClientAliveCountMax 720

# Ограничения
MaxAuthTries 3
MaxSessions 5
LoginGraceTime 30

# Протокол
Protocol 2
```

Проверьте синтаксис и перезапустите SSH:

```bash
sudo sshd -t              # проверка конфига — не должно быть ошибок
sudo systemctl restart ssh
sudo systemctl status ssh
```

Проверка из нового терминала:

```bash
ssh -p 1337 -i ~/.ssh/id_ed25519_claude pilot@<IP_VPS>
```

### 1.3.7. Установка fail2ban

Защита от брутфорса SSH:

```bash
sudo apt install fail2ban -y
```

Создайте `/etc/fail2ban/jail.local`:

```ini
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 3
banaction = ufw

[sshd]
enabled = true
port    = 1337
logpath = %(sshd_log)s
backend = systemd
```

Запустите и проверьте:

```bash
sudo systemctl enable fail2ban
sudo systemctl restart fail2ban
sudo fail2ban-client status sshd
```

### 1.3.8. Настройка firewall (ufw)

```bash
sudo apt install ufw -y

# Политики по умолчанию
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Разрешаем только нужное
sudo ufw allow 1337/tcp comment 'SSH'
sudo ufw allow 2053/tcp comment '3x-ui panel (временно)'

# Включаем
sudo ufw enable
sudo ufw status verbose
```

> ⚠️ **Важно:** не забудьте `sudo ufw allow 443/tcp` **после** создания inbound (шаг 1.5). Порт 2053 нужно будет **закрыть** после настройки панели.

### 1.3.9. Автоматические обновления безопасности

```bash
sudo apt install unattended-upgrades -y
sudo dpkg-reconfigure --priority=low unattended-upgrades
```

Проверьте `/etc/apt/apt.conf.d/20auto-upgrades`:

```
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
```

### 1.3.10. Оптимизация sysctl (для TUN и производительности)

Создайте `/etc/sysctl.d/99-claude-proxy.conf`:

```ini
# Сетевая производительность
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1

# Увеличение буферов
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Защита от некоторых атак
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
```

Примените:

```bash
sudo sysctl -p /etc/sysctl.d/99-claude-proxy.conf
```

### 1.3.11. Проверка харденинга

```bash
# SSH
sudo sshd -T | grep -E "permitrootlogin|passwordauthentication|port"

# Firewall
sudo ufw status verbose

# fail2ban
sudo fail2ban-client status sshd

# Обновления
sudo apt list --upgradable 2>/dev/null | head

# Часовой пояс
timedatectl
```

---

## 1.4. Установка 3x-ui

### 1.4.1. Что такое 3x-ui

**3x-ui** — веб-панель для управления Xray (форк X-UI). Поддерживает VLESS, VMess, Trojan, Shadowsocks, Reality, XTLS.

**Почему 3x-ui:**

- ✅ Активно развивается (в отличие от заброшенного X-UI).
- ✅ Поддержка Reality «из коробки».
- ✅ Удобная веб-панель.
- ✅ Установка одной командой.

**Альтернативы:**

- **Marzban** (более enterprise, требует больше ресурсов).
- **Xray-core вручную** (полный контроль, но сложно).
- **Hiddify Manager** (мультипротокольный, но тяжелее).

### 1.4.2. Установка

```bash
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
```

Скрипт запросит:

```
Do you want to customize the admin username? (y/n):
Do you want to customize the admin password? (y/n):
Do you want to customize the web panel port? (y/n):
```

**Отвечайте `y` на все** и задавайте:

- **Логин:** уникальный (не `admin`).
- **Пароль:** минимум 20 символов, менеджер паролей.
- **Порт:** `2053` (или любой свободный).

После установки скрипт выведет:

```
Username: <ваш_логин>
Password: <ваш_пароль>
Port: 2053
WebBasePath: <случайная_строка>
Access URL: http://<IP_VPS>:2053/<WebBasePath>
```

> 🚨 **Сохраните всё** в менеджер паролей. **`WebBasePath`** — важный секрет: без него панель не откроется даже с правильным паролем.

### 1.4.3. Проверка работы

Откройте в браузере (с вашего ПК):

```
http://<IP_VPS>:2053/<WebBasePath>
```

Войдите с логином/паролем. Если открылось — установка успешна.

> 🔒 **Сразу после настройки inbound (шаг 1.5)** закройте порт 2053 в firewall и подключайтесь к панели только через SSH-туннель:
>
> ```bash
> ssh -p 1337 -L 2053:127.0.0.1:2053 pilot@<IP_VPS>
> ```
>
> Затем открывайте `http://localhost:2053/<WebBasePath>`.

### 1.4.4. Первичная настройка панели

В панели 3x-ui:

1. **Panel Settings → General:**
   - ✅ `Enable panel traffic statistics`
   - ✅ `Auto-renew SSL` (не критично без домена)

2. **Panel Settings → Telegram Bot** (опционально):
   - Позволяет получать уведомления о входах в панель и трафике.
   - Требует создания бота через @BotFather.

3. **Xray Settings → Basic:**
   - ✅ `Xray Mux` — включить (снижает overhead).

4. **Смените `WebBasePath`** на что-то неочевидное (Panel Settings → General).

---

## 1.5. Создание inbound VLESS + Reality

> 🎯 **Цель:** создать подключение, которое маскирует трафик под обычный HTTPS к популярному сайту. Это делает его неотличимым от легитимного трафика при пассивном DPI.

### 1.5.1. Что такое Reality (кратко)

**Reality** — протокол маскировки от Xray, не требующий собственного домена и сертификата. Он «одалживает» TLS-хендшейк реального популярного сайта (например, `www.microsoft.com`), и для внешнего наблюдателя соединение выглядит как обычный HTTPS к этому сайту.

**Ключевые преимущества:**

- Не нужен домен.
- Не нужен SSL-сертификат.
- Устойчив к активному DPI (в отличие от обычного TLS).
- `xtls-rprx-vision` дополнительно снижает тайминговые паттерны TLS-in-TLS.

### 1.5.2. Выбор `Dest` (destination)

`Dest` — домен, под который маскируется трафик. Требования:

| Критерий | Как проверить |
| :--- | :--- |
| ✅ Доступен с вашего VPS | `curl -I https://www.microsoft.com` → HTTP/2 200 |
| ✅ Популярен (высокий трафик) | Любой крупный сайт |
| ✅ Поддерживает TLS 1.3 | `openssl s_client -connect www.microsoft.com:443 -tls1_3` |
| ✅ Поддерживает HTTP/2 | `curl -I --http2 https://www.microsoft.com` |
| ✅ Не заблокирован в РФ | Проверить с ПК |

**Рекомендуемые `Dest`:**

| Домен | Плюсы | Минусы |
| :--- | :--- | :--- |
| `www.microsoft.com` | Огромный трафик, TLS 1.3, HTTP/2 | Может быть в белых списках |
| `www.apple.com` | Стабилен | Меньше трафика |
| `www.wikipedia.org` | Нейтрален | — |
| `www.cloudflare.com` | Хорошая репутация | — |
| `www.amazon.com` | Огромный трафик | — |

**Проверка кандидата с VPS:**

```bash
# TLS 1.3 и HTTP/2
curl -I --http2 https://www.microsoft.com
openssl s_client -connect www.microsoft.com:443 -tls1_3 </dev/null 2>/dev/null | grep "Protocol"
```

Ожидаемый результат: `HTTP/2 200`, `Protocol : TLSv1.3`.

### 1.5.3. Создание inbound

В панели 3x-ui: **Inbounds → Add Inbound**.

#### Основные параметры

| Параметр | Значение | Комментарий |
| :--- | :--- | :--- |
| **Remark** | `claude-vless` | Произвольное имя |
| **Protocol** | `vless` | — |
| **Listen IP** | `0.0.0.0` | Или оставить пустым |
| **Port** | `443` | Стандартный HTTPS |
| **Total Traffic** | `0` (безлимит) | Или лимит по желанию |
| **Expire Date** | пусто | — |
| **Enable** | ✅ | — |

#### Параметры клиента (Client)

| Параметр | Значение |
| :--- | :--- |
| **Email** | `pilot@claude-vless` (метка) |
| **ID** | Сгенерировать кнопкой «Get New ID» (UUID v4) |
| **Flow** | `xtls-rprx-vision` |
| **Limit IP** | `1` (по желанию — защита от шаринга) |
| **Total GB** | `0` (безлимит) |
| **Expiry Time** | пусто |

#### Транспорт (Transport)

| Параметр | Значение |
| :--- | :--- |
| **Transmission** | `tcp` |
| **Security** | `reality` |

#### Reality Settings

| Параметр | Значение |
| :--- | :--- |
| **Show** | ✅ |
| **Dest** | `www.microsoft.com:443` |
| **Server Names** | `www.microsoft.com` (может быть несколько через запятую) |
| **Private Key** | Сгенерировать кнопкой «Get New Cert» |
| **Short IDs** | Сгенерировать 2–3 кнопкой «Generate» |
| **SpiderX** | `/` (или оставить пустым) |

> 🔑 **`Private Key`** — секретный ключ. **`Public Key`** будет в ссылке для клиента. Не публикуйте `Private Key`.

#### Sniffing

| Параметр | Значение |
| :--- | :--- |
| **Enable** | ✅ |
| **Dest Override** | `none` |
| **Metadata Only** | ✅ |
| **Route Only** | ❌ |
| **Domains Excluded** | пусто |

**Sniffing** нужен для корректного определения доменов при маршрутизации.

### 1.5.4. Сохранение и получение ссылки

После сохранения в списке Inbounds появится ваш `claude-vless`. Нажмите на него → **QR-код** или **Info** → скопируйте ссылку.

Ссылка выглядит так:

```
vless://<UUID>@<IP_VPS>:443?type=tcp&security=reality&pbk=<PUBLIC_KEY>&fp=chrome&sni=www.microsoft.com&sid=<SHORT_ID>&spx=%2F&flow=xtls-rprx-vision#claude-vless
```

> 🚨 **Сохраните ссылку** в менеджере паролей. Она понадобится на шаге 2.1 (настройка ПК).

### 1.5.5. Открытие порта 443 в firewall

```bash
sudo ufw allow 443/tcp comment 'VLESS Reality'
sudo ufw reload
sudo ufw status verbose
```

### 1.5.6. Закрытие панели от публичного доступа

```bash
# Удаляем правило для 2053
sudo ufw delete allow 2053/tcp

# Проверяем
sudo ufw status verbose
```

Теперь панель доступна только через SSH-туннель:

```bash
ssh -p 1337 -i ~/.ssh/id_ed25519_claude -L 2053:127.0.0.1:2053 pilot@<IP_VPS>
```

Откройте `http://localhost:2053/<WebBasePath>` в браузере.

### 1.5.7. Проверка inbound с ПК

Временно, до настройки клиента (шаг 2.1), проверьте с ПК:

```bash
# Проверяем, что порт 443 открыт
nc -vz <IP_VPS> 443
```

Или через онлайн-сервис [`check-host.net`](https://check-host.net).

---

## 1.6. Опционально: WARP для маскировки исходящего трафика

> ⚠️ **Этот шаг опционален.** Он не требуется для базовой схемы. Используйте его, если хотите, чтобы исходящий трафик к Anthropic шёл не с IP вашего хостинга, а через Cloudflare WARP.

### 1.6.1. Зачем

- Снижает риск, что IP вашего хостинга попадёт в поле зрения антифрода как «подозрительный диапазон».
- Добавляет уровень изоляции между вашим VPS и Anthropic.

### 1.6.2. Установка WARP

```bash
# Добавляем репозиторий Cloudflare
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | sudo gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflare-client.list

# Устанавливаем
sudo apt update
sudo apt install cloudflare-warp -y

# Регистрация
warp-cli registration new

# Режим SOCKS5-прокси
warp-cli mode proxy
warp-cli connect

# Проверка
curl --socks5 127.0.0.1:40000 https://ifconfig.me
```

> ✅ Должен вернуть IP Cloudflare, не ваш VPS.

### 1.6.3. Настройка Outbound в 3x-ui

В панели 3x-ui → **Xray Settings → Outbounds → Add Outbound**:

| Параметр | Значение |
| :--- | :--- |
| **Protocol** | `socks` |
| **Tag** | `warp` |
| **Address** | `127.0.0.1` |
| **Port** | `40000` |

Затем в **Xray Settings → Routing → Add Rule**:

| Параметр | Значение |
| :--- | :--- |
| **Domain** | `domain:anthropic.com,domain:claude.ai,domain:openai.com` |
| **Outbound Tag** | `warp` |

> ⚠️ **Предупреждение:** при использовании `warp-cli` в режиме `proxy` существует потенциальная утечка реального IP VPS по UDP. Если это критично — используйте альтернативу через Dante-прокси или откажитесь от WARP.

---

## 1.7. Мониторинг, обслуживание и бэкапы

### 1.7.1. Мониторинг Fraud Score

Раз в неделю проверяйте `scamalytics.com` и `abuseipdb.com`. Если Fraud Score растёт — рассмотрите пересоздание VPS.

### 1.7.2. Логи и их ротация

Xray пишет логи в `/usr/local/x-ui/`. Ограничьте размер:

```bash
sudo nano /etc/logrotate.d/x-ui
```

```
/usr/local/x-ui/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
```

### 1.7.3. Бэкап конфигурации 3x-ui

Еженедельно (через cron на вашем ПК или вручную):

```bash
# На VPS
sudo cp -r /etc/x-ui /root/backup-$(date +%Y%m%d)
sudo tar czf /root/x-ui-backup-$(date +%Y%m%d).tar.gz /etc/x-ui /usr/local/x-ui/bin/config.json
```

Скачайте на ПК:

```bash
scp -P 1337 -i ~/.ssh/id_ed25519_claude pilot@<IP_VPS>:/root/x-ui-backup-*.tar.gz ~/backups/
```

> 🔒 **Храните бэкапы** в защищённом месте: они содержат `Private Key` и все UUID.

### 1.7.4. Обновление 3x-ui

```bash
# Проверка версии
/usr/local/x-ui/x-ui -v

# Обновление
cd /usr/local/x-ui
sudo ./x-ui update
```

> ⚠️ Перед обновлением **сделайте бэкап** (см. 1.7.3). Обновления иногда ломают конфиги.

### 1.7.5. Мониторинг ресурсов

```bash
# Простая проверка
htop
df -h
free -h

# Логи Xray
sudo journalctl -u x-ui -f
```

Для серьёзного мониторинга — **Netdata** или **Prometheus + Grafana** (опционально).

---

## 1.8. Troubleshooting

### Проблема: панель 3x-ui не открывается

| Причина | Решение |
| :--- | :--- |
| Firewall блокирует 2053 | `sudo ufw allow 2053/tcp`, затем после настройки закрыть |
| Неверный `WebBasePath` | Смотрите `/etc/x-ui/x-ui.db` или переустановите |
| Служба не запущена | `sudo systemctl status x-ui`, `sudo systemctl restart x-ui` |

### Проблема: клиент не подключается к VLESS

| Причина | Решение |
| :--- | :--- |
| Порт 443 закрыт | `sudo ufw allow 443/tcp` |
| Неверный `Public Key` в ссылке | Перегенерируйте ключи в inbound, обновите ссылку |
| `Dest` недоступен с VPS | `curl -I https://www.microsoft.com` — если не работает, смените `Dest` |
| `Short ID` не совпадает | Проверьте в inbound и в ссылке |

### Проблема: соединение есть, но трафик не идёт

| Причина | Решение |
| :--- | :--- |
| DNS не резолвится | Проверьте `cat /etc/resolv.conf`, должно быть `1.1.1.1` или `8.8.8.8` |
| Маршрутизация Xray блокирует | Проверьте Outbound и Routing в 3x-ui |
| Провайдер блокирует 443 | Смените порт на 8443 или 2053 (и настройте firewall) |

### Проблема: SSH не пускает после харденинга

| Причина | Решение |
| :--- | :--- |
| Забыли SSH-ключ | Войдите через **веб-консоль** провайдера и восстановите `authorized_keys` |
| Неверный порт | Используйте `-p 1337` |
| fail2ban забанил | Через веб-консоль: `sudo fail2ban-client set sshd unbanip <ваш_IP>` |

### Проблема: WARP не работает

| Причина | Решение |
| :--- | :--- |
| Не подключён | `warp-cli status`, `warp-cli connect` |
| Порт 40000 занят | `sudo ss -tlnp | grep 40000` |
| Провайдер блокирует WARP | Откажитесь от WARP, используйте прямое подключение |

### Логи для диагностики

```bash
# Xray
sudo journalctl -u x-ui -n 100 --no-pager
sudo tail -f /usr/local/x-ui/access.log
sudo tail -f /usr/local/x-ui/error.log

# SSH
sudo journalctl -u ssh -n 50 --no-pager

# fail2ban
sudo fail2ban-client status sshd

# firewall
sudo ufw status verbose
```

---

## 🔒 Финальный чек-лист безопасности

| № | Проверка | Команда / инструмент | ✅ |
| :--- | :--- | :--- | :---: |
| 1 | Fraud Score IP < 30 | `scamalytics.com` | ☐ |
| 2 | AbuseIPDB confidence < 25% | `abuseipdb.com` | ☐ |
| 3 | Root-логин по SSH отключён | `sudo sshd -T \| grep permitrootlogin` | ☐ |
| 4 | Парольная аутентификация отключена | `sudo sshd -T \| grep passwordauthentication` | ☐ |
| 5 | SSH на нестандартном порту | `sudo sshd -T \| grep port` | ☐ |
| 6 | fail2ban активен | `sudo fail2ban-client status sshd` | ☐ |
| 7 | ufw активен, открыты только 443 и SSH | `sudo ufw status verbose` | ☐ |
| 8 | Панель 3x-ui закрыта от публичного доступа | `sudo ufw status verbose \| grep 2053` (должно быть пусто) | ☐ |
| 9 | Часовой пояс VPS = страна IP | `timedatectl` | ☐ |
| 10 | Автообновления включены | `cat /etc/apt/apt.conf.d/20auto-upgrades` | ☐ |
| 11 | sysctl BBR активен | `sysctl net.ipv4.tcp_congestion_control` | ☐ |
| 12 | Inbound VLESS+Reality создан | 3x-ui панель | ☐ |
| 13 | Ссылка VLESS сохранена в менеджере паролей | — | ☐ |
| 14 | Бэкап конфигурации сделан | `/root/x-ui-backup-*.tar.gz` | ☐ |
| 15 | Логи ротация настроена | `/etc/logrotate.d/x-ui` | ☐ |

---

## 📌 Что дальше

После успешного завершения Части 1 у вас есть:

- ✅ Защищённый VPS с «чистым» IP.
- ✅ Работающий inbound VLESS+Reality на порту 443.
- ✅ Ссылка для подключения клиента.
- ✅ Бэкап и мониторинг.

**Следующий шаг:** [Часть 2 — Настройка ПК в России](pc-setup.md) — установка клиента VLESS, антидетект-браузера и системных переменных окружения.

---

<div align="center">

**⚠️ Используйте на свой риск. Абсолютной гарантии от блокировки не существует.**

[⬆ Наверх](#️-vps-setup--расширенное-руководство) · [📖 К оглавлению серии](../README.md)

</div>
