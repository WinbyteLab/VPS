# ⚙️ Tools Setup — расширенное руководство

> **Часть 3 из серии руководств по построению стабильной инфраструктуры доступа к Claude AI.**
> Детальная настройка Claude Desktop, Claude Code, VS Code, Cursor, LM Studio, Gemini CLI и Codex CLI для работы через локальный HTTP-прокси VLESS-клиента.

[![Part](https://img.shields.io/badge/part-3%20of%203-blue)]()
[![Level](https://img.shields.io/badge/level-intermediate--advanced-orange)]()
[![Time](https://img.shields.io/badge/time-40--60%20min-yellow)]()
[![Tools](https://img.shields.io/badge/tools-Claude%20%7C%20VS%20Code%20%7C%20Cursor%20%7C%20LM%20Studio%20%7C%20Gemini%20%7C%20Codex-lightgrey)]()

---

## ⚠️ Дисклеймер

> Руководство носит исключительно технический и образовательный характер. Автор не гарантирует отсутствие блокировок со стороны Anthropic и не призывает к нарушению Terms of Service. Используйте на свой риск. Соблюдайте законодательство своей страны.

---

## 📖 Оглавление

- [0. Предварительные требования](#0-предварительные-требования)
- [3.1. Claude Desktop](#31-claude-desktop)
- [3.2. Claude Code (CLI)](#32-claude-code-cli)
- [3.3. VS Code](#33-vs-code)
- [3.4. Cursor IDE](#34-cursor-ide)
- [3.5. LM Studio](#35-lm-studio)
- [3.6. Gemini CLI](#36-gemini-cli)
- [3.7. Codex CLI](#37-codex-cli)
- [3.8. Сводная таблица](#38-сводная-таблица)
- [🔒 Финальный чек-лист](#-финальный-чек-лист)

---

## 0. Предварительные требования

### Что должно быть готово **до** начала

| Компонент | Откуда взять |
| :--- | :--- |
| **Работающий VPS с inbound VLESS+Reality** | [Часть 1 — vps-setup.md](vps-setup.md) |
| **Клиент VLESS (v2rayN / Hiddify) с HTTP-прокси на `10809`** | [Часть 2 — pc-setup.md](pc-setup.md), шаг 2.1.5 |
| **Системные переменные `HTTP_PROXY` / `HTTPS_PROXY`** | [Часть 2 — pc-setup.md](pc-setup.md), шаг 2.3 |
| **Проверенный антидетект-профиль для веб-версии Claude** | [Часть 2 — pc-setup.md](pc-setup.md), шаг 2.2 |

### Ключевое ограничение, общее для всех инструментов

> **Все CLI-инструменты в этой схеме (Claude Code, Gemini CLI, Codex CLI) и большинство IDE-настроек работают только с HTTP/HTTPS-прокси. SOCKS5 не поддерживается.**
>
> В v2rayN HTTP-прокси слушает `127.0.0.1:10809`, SOCKS5 — `127.0.0.1:10808`. **Везде ниже используется порт `10809`.** Если вы изменили порт в настройках v2rayN — замените его во всех примерах.

### Архитектура подключения инструментов

```
┌─────────────────────────────────────────────────────────────┐
│  Claude Desktop    →  системный прокси ОС  ─┐               │
│  Claude Code       →  HTTPS_PROXY env      ─┤               │
│  VS Code           →  http.proxy           ─┤               │
│  Cursor            →  http.proxy           ─┼→  127.0.0.1:10809
│  Gemini CLI        →  HTTPS_PROXY env      ─┤   (HTTP-прокси
│  Codex CLI         →  HTTPS_PROXY env      ─┤    v2rayN)
│  LM Studio (GUI)   →  локальный, без прокси│               │
└─────────────────────────────────────────────┘               │
                                                              ▼
                                                    VPS (VLESS+Reality)
```

---

## 3.1. Claude Desktop

### 3.1.1. Как Claude Desktop работает с прокси

Claude Desktop — Electron-приложение, но его архитектура неоднородна. **Три части продукта** делают сетевые соединения, и они резолвят прокси **по-разному** [reference:0]:

| Часть | Что делает | Как резолвит прокси |
| :--- | :--- | :--- |
| **App (окно)** | Вход, тест соединения, Web Fetch в Chat/Cowork, MCP-серверы, синхронизация плагинов | Читает настройки прокси **ОС**, включая PAC |
| **Agent (движок Claude Code)** | Inference-запросы, web fetch в Code-сессиях, удалённые MCP | **Не читает ОС напрямую.** При старте сессии App спрашивает ОС, какой прокси применим к inference-эндпоинту, и передаёт агенту результат как `HTTPS_PROXY` / `HTTP_PROXY` [reference:1] |
| **Cowork sandbox (shell)** | `curl`, `pip`, `npm` внутри Cowork-сессии | На macOS/Windows — следует настройкам ОС; на Linux — **прокси не передаётся** [reference:2] |

**Критическое ограничение:** агенту передаются **только `http://` и `https://` прокси**. Если ОС возвращает SOCKS-прокси, приложение его **пропускает**, и агент подключается напрямую [reference:3]. Поэтому системный прокси для Claude Desktop должен быть **HTTP**, а не SOCKS.

### 3.1.2. Вариант А — системный прокси (проще)

Если ваш VLESS-клиент работает в режиме **System Proxy** и поднимает HTTP-прокси на `10809`, Claude Desktop **скорее всего** подхватит его автоматически.

**Проверка:**

1. Убедитесь, что в v2rayN включён **System Proxy** и HTTP-прокси на `10809`.
2. Запустите Claude Desktop.
3. Войдите в аккаунт.
4. Если вход проходит — системный прокси подхватился.

**Ограничение:** этот вариант работает не всегда. Агент может не получить прокси, если ОС возвращает SOCKS, или если системные настройки изменились после запуска Desktop [reference:4].

### 3.1.3. Вариант Б — принудительное закрепление через `egressProxyUrl` (надёжнее)

Claude Desktop читает `egressProxyUrl` из управляемой конфигурации. На **Windows** это значение `REG_SZ` в ветке `HKLM\SOFTWARE\Policies\Claude` [reference:5].

**Настройка (PowerShell от имени администратора):**

```powershell
New-Item -Path "HKLM:\SOFTWARE\Policies\Claude" -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Claude" `
                 -Name "egressProxyUrl" `
                 -Value "http://127.0.0.1:10809" `
                 -Type String
```

**Что это даёт:** и приложение, и агент будут использовать указанный HTTP-прокси **независимо от системных настроек**. Это «pinning» — прокси закрепляется для всего трафика продукта [reference:6].

**Важные ограничения:**

| Ограничение | Детали |
| :--- | :--- |
| **Только `http://` / `https://`** | SOCKS не принимается [reference:7] |
| **Нет интерактивной аутентификации** | Если прокси требует логин/пароль, запрос провалится. Локальный v2rayN обычно не требует auth [reference:8] |
| **TLS-инспекция** | Если прокси подменяет сертификаты, Desktop может отказаться работать. Для VLESS-схемы TLS-инспекции нет — сертификаты end-to-end [reference:9] |
| **Managed settings приоритетнее** | Если Claude Code имеет собственные managed settings, они могут переопределить `egressProxyUrl` [reference:10] |

### 3.1.4. Чего **не** делает Claude Desktop

- ❌ **Не маршрутизирует весь системный трафик** — только свой.
- ❌ **Не поддерживает SOCKS** — ни в системном прокси, ни в `egressProxyUrl`.
- ❌ **Не читает `HTTPS_PROXY` из окружения** для основной части приложения (только для агента, и только если ОС вернула HTTP-прокси).
- ❌ **Не имеет GUI-настройки прокси** (по состоянию на 2026) [reference:11].

### 3.1.5. Проверка

1. Установите `egressProxyUrl` (или включите System Proxy).
2. **Полностью закройте** Claude Desktop (включая трей).
3. Запустите снова.
4. Войдите в аккаунт.
5. Отправьте тестовый запрос.
6. Если запрос уходит и приходит ответ — прокси работает.

> ⚠️ **Если Desktop «висит» на входе** — проверьте, что `curl -x http://127.0.0.1:10809 https://api.anthropic.com` возвращает ответ. Если `curl` не работает, проблема в VLESS-клиенте, а не в Desktop.

---

## 3.2. Claude Code (CLI)

### 3.2.1. Как Claude Code работает с прокси

Claude Code — Node.js CLI. Он читает стандартные переменные в порядке приоритета [reference:12]:

```
https_proxy → HTTPS_PROXY → http_proxy → HTTP_PROXY
```

**Критическое ограничение:** Claude Code **не поддерживает SOCKS-прокси** — только `http://` и `https://` [reference:13].

В сессиях Claude Desktop, где приложение управляет подключением провайдера, Claude Code читает прокси **только** из managed settings и `~/.claude/settings.json` [reference:14]. В обычном CLI-режиме — из окружения.

### 3.2.2. Минимальная настройка — переменные окружения

Если вы выполнили шаг 2.3 из Части 2, переменные уже установлены на уровне пользователя Windows. Проверьте в **новом** терминале:

```powershell
$env:HTTPS_PROXY
# Должно вернуть: http://127.0.0.1:10809
```

**Проверка соединения:**

```powershell
curl.exe -x http://127.0.0.1:10809 https://api.anthropic.com -I
# HTTP/2 401 (или 403) — нормально, соединение установлено
```

### 3.2.3. Постоянная настройка через `~/.claude/settings.json`

Чтобы не зависеть от переменных окружения (которые могут сбрасываться), задайте `env`-блок в `~/.claude/settings.json`:

```json
{
  "env": {
    "HTTPS_PROXY": "http://127.0.0.1:10809",
    "HTTP_PROXY":  "http://127.0.0.1:10809",
    "NO_PROXY":    "localhost,127.0.0.1,::1"
  }
}
```

Этот файл читается Claude Code при старте. `env`-блок применяется ко всем сессиям, включая фоновые агенты [reference:15].

### 3.2.4. Аутентификация в прокси (если требуется)

Если ваш прокси требует Basic Auth (не ваш случай с v2rayN, но на будущее), credentials включаются в URL:

```json
{
  "env": {
    "HTTPS_PROXY": "http://username:password@proxy.example.com:8080"
  }
}
```

> ⚠️ **Не хардкодьте пароли** в скриптах. Используйте менеджер секретов или переменные окружения [reference:16].

### 3.2.5. `NO_PROXY` — обязательный минимум

Claude Code **никогда** не отправляет WebSocket-соединения к `localhost`, `::1` или `127.0.0.0/8` через прокси [reference:17]. Однако для OAuth-callback и других локальных сценариев **настоятельно рекомендуется** явно указать:

```
NO_PROXY=localhost,127.0.0.1,::1
```

Без этого возможны проблемы с входом, если OAuth-редирект идёт на loopback-адрес.

### 3.2.6. CA-сертификаты

По умолчанию Claude Code доверяет **встроенному набору Mozilla CA** и **системному хранилищу** [reference:18]. Для VLESS-схемы (без TLS-инспекции) **ничего настраивать не нужно**.

Если в будущем вы используете прокси с TLS-инспекцией:

```json
{
  "env": {
    "NODE_EXTRA_CA_CERTS": "/path/to/corporate-ca.pem"
  }
}
```

Или через `CLAUDE_CODE_CERT_STORE`:

```json
{
  "env": {
    "CLAUDE_CODE_CERT_STORE": "bundled,system"
  }
}
```

### 3.2.7. Проверка

```powershell
# В новом терминале
claude --version
# Должно вывести версию без ошибок сети
```

Запустите тестовую сессию:

```powershell
claude
# Введите простой запрос, например: "What is 2+2?"
# Если ответ приходит — прокси работает
```

---

## 3.3. VS Code

### 3.3.1. Два независимых механизма

VS Code имеет **два** механизма прокси:

1. **Собственный `http.proxy`** — влияет на встроенный HTTP-клиент VS Code (обновления, Marketplace, некоторые расширения) [reference:19].
2. **Переменные окружения** — наследуются дочерними процессами: встроенным терминалом, расширениями, задачами.

> ⚠️ **Ограничение `http.proxy`:** он влияет **только** на встроенный HTTP-клиент VS Code. Расширения, которые делают прямые API-вызовы, могут его игнорировать [reference:20]. Для них нужны переменные окружения.

### 3.3.2. Настройка через `settings.json`

Откройте `settings.json` (`Ctrl+Shift+P` → `Preferences: Open User Settings (JSON)`) и добавьте:

```json
{
  "http.proxy": "http://127.0.0.1:10809",
  "http.proxySupport": "override",
  "http.proxyStrictSSL": false,
  "http.noProxy": ["localhost", "127.0.0.1"]
}
```

| Параметр | Значение | Комментарий |
| :--- | :--- | :--- |
| `http.proxy` | `http://127.0.0.1:10809` | Адрес локального HTTP-прокси |
| `http.proxySupport` | `"override"` | Принудительно использовать прокси, даже если ОС настроена иначе [reference:21] |
| `http.proxyStrictSSL` | `false` | Не проверять SSL для прокси (для VLESS не требуется, но безопасно) |
| `http.noProxy` | `["localhost", "127.0.0.1"]` | Исключения |

### 3.3.3. Настройка через переменные окружения

Если VS Code запущен из терминала с установленными `HTTPS_PROXY` / `HTTP_PROXY`, он и **все его дочерние процессы** унаследуют их. Это единственный способ заставить расширения, которые не читают `http.proxy`, использовать прокси.

**Запуск из PowerShell:**

```powershell
$env:HTTPS_PROXY="http://127.0.0.1:10809"
$env:HTTP_PROXY="http://127.0.0.1:10809"
code .
```

**Постоянный алиас (PowerShell profile):**

```powershell
function code-proxy {
    $env:HTTPS_PROXY="http://127.0.0.1:10809"
    $env:HTTP_PROXY="http://127.0.0.1:10809"
    code $args
}
```

### 3.3.4. AI-расширения с собственными настройками

Расширения вроде **Continue**, **Cline**, **Roo Code** могут иметь **собственные** настройки прокси, независимые от `http.proxy`. Если запросы в расширении не идут — проверьте его настройки:

| Расширение | Где искать |
| :--- | :--- |
| Continue | `Continue: Open Config` → `proxy` |
| Cline | Settings → Network → Proxy |
| Roo Code | Settings → Proxy |

### 3.3.5. Проверка

1. Откройте Command Palette (`Ctrl+Shift+P`).
2. Выполните `Developer: Reload Window`.
3. Откройте встроенный терминал (`Ctrl+``).
4. Проверьте: `curl.exe -x http://127.0.0.1:10809 https://api.anthropic.com -I`.

Если встроенный терминал наследует переменные и `curl` работает — настройка корректна.

---

## 3.4. Cursor IDE

### 3.4.1. Специфика Cursor: HTTP/2

Cursor — форк VS Code, но имеет **критическое отличие**: он использует **HTTP/2** для стриминга ответов моделей. Некоторые прокси-конфигурации (особенно при нестабильном HTTP/2-туннелировании) ломают стриминг: запрос уходит, но ответ «зависает» или приходит целиком в конце.

**Симптом:** Cursor показывает «Generating…» и не выдаёт токены, хотя сеть работает [reference:22].

### 3.4.2. Рекомендуемая конфигурация `settings.json`

Откройте `settings.json` Cursor (`Ctrl+Shift+P` → `Preferences: Open User Settings (JSON)`):

```json
{
  "http.proxy": "http://127.0.0.1:10809",
  "http.proxySupport": "override",
  "http.proxyStrictSSL": false,
  "http.noProxy": ["localhost", "127.0.0.1"],
  "cursor.general.disableHttp2": true
}
```

| Параметр | Значение | Почему |
| :--- | :--- | :--- |
| `http.proxy` | `http://127.0.0.1:10809` | Адрес прокси [reference:23] |
| `http.proxySupport` | `"override"` | Принудительное использование [reference:24] |
| `http.proxyStrictSSL` | `false` | Совместимость [reference:25] |
| `http.noProxy` | `["localhost", "127.0.0.1"]` | Исключения |
| **`cursor.general.disableHttp2`** | **`true`** | **Критически важно** для прокси [reference:26] |

> 🔑 **`cursor.general.disableHttp2: true` — это официально поддерживаемый ключ**, который принудительно переводит Cursor на HTTP/1.1. Это **устраняет** «зависающий стриминг» через прокси [reference:27].

### 3.4.3. Если стриминг всё равно нестабилен

Попробуйте дополнительно:

```json
{
  "cursor.general.disableHttp1SSE": true
}
```

Это отключает Server-Sent Events через HTTP/1.1 (если они тоже ломаются).

### 3.4.4. Альтернатива: Proxifier

Если встроенный прокси-стек Cursor ведёт себя нестабильно, используйте **Proxifier** (Windows) с правилом:

```
*.cursor.sh → SOCKS5 127.0.0.1:10808
```

Это обходит встроенный прокси-стек Cursor полностью на уровне сетевых сокетов.

### 3.4.5. Проверка

1. Перезапустите Cursor после изменения `settings.json`.
2. Откройте чат Cursor.
3. Отправьте запрос.
4. **Ожидаемое поведение:** ответ появляется токен за токеном (стриминг), а не целиком в конце.
5. Если ответ «зависает» — проверьте, что `disableHttp2: true` действительно сохранён (перезапустите Cursor).

> ⚠️ **Cursor может «кешировать» ошибки региона.** Если вы видите `Model not available. This model provider doesn't serve your region`, но прокси работает — полностью закройте Cursor, очистите кеш (если есть опция), перезапустите.

---

## 3.5. LM Studio

### 3.5.1. Основной сценарий — GUI на ПК

**LM Studio для локального инференса не требует прокси.** Он работает с локальными моделями и не обращается к серверам Anthropic.

> ✅ **Если вы не используете LM Studio как удалённый API — ничего настраивать не нужно.** Запускайте GUI как обычно.

### 3.5.2. Сценарий headless на VPS (опционально)

Если вы хотите, чтобы LM Studio отдавал OpenAI-совместимый API **с вашего VPS** (например, для Claude Code через кастомный провайдер), используйте **`llmster`** — headless-демон LM Studio [reference:28].

**Установка на VPS (Linux):**

```bash
curl -fsSL https://lmstudio.ai/install.sh | bash
```

**Запуск демона:**

```bash
lms daemon up
```

**Запуск API-сервера:**

```bash
lms server start --port 1234 --bind 127.0.0.1
```

> 🔒 **Безопасность:** **никогда** не биндите LM Studio на `0.0.0.0` без аутентификации. `--bind 127.0.0.1` гарантирует, что сервер доступен только с самого VPS. Для удалённого доступа используйте SSH-туннель:
>
> ```bash
> ssh -p 1337 -L 1234:127.0.0.1:1234 pilot@<IP_VPS>
> ```

**JIT-загрузка моделей:** при включённой JIT-загрузке вызовы `/v1/models` возвращают все скачанные модели, а inference-эндпоинты автоматически загружают модель в память при первом запросе [reference:29]. Это удобно для API-сервера.

### 3.5.3. Что **не** делает LM Studio

- ❌ **Не маршрутизирует трафик Claude** — он работает с локальными моделями.
- ❌ **Не требует прокси** для GUI-режима.
- ❌ **Не поддерживает VLESS напрямую** — если нужен удалённый доступ, используйте SSH-туннель.

---

## 3.6. Gemini CLI

### 3.6.1. Как Gemini CLI работает с прокси

Gemini CLI — Node.js CLI. Он читает **стандартные переменные** `HTTPS_PROXY` / `HTTP_PROXY` [reference:30].

**Важное отличие:** Node.js читает TLS-переменные (`NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`, `HTTPS_PROXY`) **один раз при старте процесса**, в C++ до выполнения любого пользовательского JS [reference:31]. Поэтому переменные должны быть установлены **до** запуска `gemini`, а не через `.env` внутри процесса.

### 3.6.2. Минимальная настройка

Если вы выполнили шаг 2.3 из Части 2 — **ничего дополнительно делать не нужно**. Gemini CLI унаследует `HTTPS_PROXY` из окружения.

**Проверка:**

```powershell
$env:HTTPS_PROXY
# http://127.0.0.1:10809
```

**Запуск:**

```powershell
gemini
# Введите тестовый запрос
```

### 3.6.3. Временный прокси только для одного запуска

```powershell
# PowerShell
$env:HTTPS_PROXY="http://127.0.0.1:10809"
$env:HTTP_PROXY="http://127.0.0.1:10809"
gemini
```

### 3.6.4. `~/.gemini/.env` (если нужна постоянная настройка)

Gemini CLI читает `~/.gemini/.env` (и `.gemini/.env` в родительских директориях). Однако **только для узкого списка TLS/сетевых переменных** они инжектируются в дочерний процесс до инициализации Node TLS [reference:32].

Создайте `~/.gemini/.env`:

```env
HTTPS_PROXY=http://127.0.0.1:10809
HTTP_PROXY=http://127.0.0.1:10809
NO_PROXY=localhost,127.0.0.1,::1
```

> ⚠️ **Ограничение:** `.env` работает только для `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY`, `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`, `SSL_CERT_DIR`, `NODE_TLS_REJECT_UNAUTHORIZED` [reference:33]. Другие переменные через `.env` могут не подхватиться до инициализации TLS.

### 3.6.5. SOCKS5

Gemini CLI, как и Claude Code, **не поддерживает SOCKS5** для основного трафика. Используйте HTTP-порт `10809`.

---

## 3.7. Codex CLI

### 3.7.1. Как Codex CLI работает с прокси

Codex CLI написан на **Rust** (runtime: `reqwest`). Он имеет **отличия** от Node.js-инструментов:

| Параметр | Поведение |
| :--- | :--- |
| **Прокси** | Читает `HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY` [reference:34] |
| **PAC / WPAD** | ❌ **Не поддерживает** автоматическое обнаружение [reference:35] |
| **SOCKS5** | ❌ **Не поддерживается** — только HTTP/HTTPS [reference:36] |
| **CA-сертификаты** | `CODEX_CA_CERTIFICATE` (fallback: `SSL_CERT_FILE`) [reference:37] |

### 3.7.2. Минимальная настройка

Если переменные установлены на шаге 2.3 — Codex CLI унаследует их.

**Проверка:**

```powershell
$env:HTTPS_PROXY
# http://127.0.0.1:10809
```

**Запуск:**

```powershell
codex
```

### 3.7.3. Постоянная настройка: `~/.codex/.env`

Codex CLI читает `.env`-файл в корне проекта или в `~/.codex/`. Создайте `~/.codex/.env`:

```env
HTTP_PROXY=http://127.0.0.1:10809
HTTPS_PROXY=http://127.0.0.1:10809
NO_PROXY=localhost,127.0.0.1,::1
```

Это избавит от необходимости выставлять переменные в каждом терминале.

### 3.7.4. CA-сертификаты (для TLS-инспекции — не ваш случай)

Если в будущем вы используете прокси с TLS-инспекцией, Codex CLI принимает корневой CA через `CODEX_CA_CERTIFICATE`:

```powershell
$env:CODEX_CA_CERTIFICATE="C:\certs\corporate-ca.pem"
```

> ✅ Для VLESS-схемы **без TLS-инспекции** это **не требуется**. Сертификаты end-to-end.

### 3.7.5. Отладка

Codex CLI поддерживает `RUST_LOG=debug` для детального вывода сетевых операций [reference:38]:

```powershell
$env:RUST_LOG="debug"
codex
```

Это поможет диагностировать, идёт ли трафик через прокси.

---

## 3.8. Сводная таблица

| Инструмент | Механизм прокси | SOCKS5 | Где настраивать | Критическая заметка |
| :--- | :--- | :---: | :--- | :--- |
| **Claude Desktop** | Системный прокси + `egressProxyUrl` | ❌ | Реестр Windows (`HKLM\SOFTWARE\Policies\Claude`) | Агент получает только HTTP-прокси; SOCKS пропускается [reference:39] |
| **Claude Code** | `HTTPS_PROXY` / `settings.json` | ❌ | `~/.claude/settings.json` → `env` | Только HTTP/HTTPS [reference:40] |
| **VS Code** | `http.proxy` + env | ❌ (для `http.proxy`) | `settings.json` | `http.proxy` не покрывает все расширения [reference:41] |
| **Cursor** | `http.proxy` + env | ❌ | `settings.json` | **`disableHttp2: true` обязателен** [reference:42] |
| **LM Studio (GUI)** | Не требуется | — | — | Локальный инференс |
| **LM Studio (headless)** | Не требуется для API | — | `lms server start --bind 127.0.0.1` | Только SSH-туннель для доступа |
| **Gemini CLI** | `HTTPS_PROXY` + `~/.gemini/.env` | ❌ | `~/.gemini/.env` | Node.js читает TLS-переменные до JS [reference:43] |
| **Codex CLI** | `HTTPS_PROXY` + `~/.codex/.env` | ❌ | `~/.codex/.env` | Не читает PAC/WPAD [reference:44] |

---

## 🔒 Финальный чек-лист

| № | Инструмент | Проверка | ✅ |
| :--- | :--- | :--- | :---: |
| 1 | **Claude Desktop** | Вход и тестовый запрос проходят | ☐ |
| 2 | **Claude Desktop** | `egressProxyUrl` установлен (если используется Вариант Б) | ☐ |
| 3 | **Claude Code** | `claude --version` без ошибок сети | ☐ |
| 4 | **Claude Code** | Тестовая сессия `claude` возвращает ответ | ☐ |
| 5 | **Claude Code** | `~/.claude/settings.json` содержит `env`-блок | ☐ |
| 6 | **VS Code** | `http.proxy` = `http://127.0.0.1:10809` | ☐ |
| 7 | **VS Code** | Встроенный терминал: `curl -x http://127.0.0.1:10809 https://api.anthropic.com` работает | ☐ |
| 8 | **Cursor** | `settings.json` содержит `http.proxy` и **`cursor.general.disableHttp2: true`** | ☐ |
| 9 | **Cursor** | Чат стримит ответы (не «зависает») | ☐ |
| 10 | **LM Studio (GUI)** | Работает без прокси (локальные модели) | ☐ |
| 11 | **LM Studio (headless)** | `lms server start --bind 127.0.0.1` запущен на VPS | ☐ |
| 12 | **Gemini CLI** | `gemini` запускается без ошибок сети | ☐ |
| 13 | **Gemini CLI** | `~/.gemini/.env` содержит `HTTPS_PROXY` | ☐ |
| 14 | **Codex CLI** | `codex` запускается без ошибок сети | ☐ |
| 15 | **Codex CLI** | `~/.codex/.env` содержит `HTTPS_PROXY` | ☐ |
| 16 | **Все** | `curl -x http://127.0.0.1:10809 https://api.anthropic.com -I` возвращает HTTP-статус | ☐ |
| 17 | **Все** | Ни один инструмент не использует SOCKS5 (только HTTP) | ☐ |

> ⚠️ **Не начинайте полноценную работу**, пока все пункты не выполнены. Один инструмент, ходящий напрямую (в обход прокси), может «слить» российский IP и создать несоответствие в цифровом отпечатке.

---

## 📌 Что дальше

После завершения Части 3 у вас есть:

- ✅ Claude Desktop с закреплённым HTTP-прокси.
- ✅ Claude Code, Gemini CLI и Codex CLI с постоянными настройками прокси.
- ✅ VS Code и Cursor с корректными `http.proxy` и `disableHttp2`.
- ✅ LM Studio — локально (GUI) или на VPS (headless).
- ✅ Все инструменты используют **HTTP-прокси** `127.0.0.1:10809` и **не пытаются** использовать SOCKS.

**Вернуться к началу серии:** [README.md](../README.md)

---

<div align="center">

**⚠️ Используйте на свой риск. Абсолютной гарантии от блокировки не существует.**

[⬆ Наверх](#️-tools-setup--расширенное-руководство) · [📖 К оглавлению серии](../README.md)

</div>
