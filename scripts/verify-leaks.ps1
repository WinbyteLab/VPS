#Requires -Version 5.1
<#
.SYNOPSIS
    verify-leaks.ps1 — Проверка утечек и консистентности конфигурации для схемы Claude AI.

.DESCRIPTION
    Скрипт проверяет готовность Windows-ПК к работе со схемой доступа к Claude AI
    через VLESS+Reality-прокси. Выполняет 14 категорий проверок:

      1.  Окружение (PowerShell, версия, права)
      2.  Системный прокси (реестр Windows)
      3.  Переменные окружения HTTP_PROXY / HTTPS_PROXY / NO_PROXY
      4.  Доступность локального прокси (порт 10809)
      5.  Внешний IP через прокси (должен быть IP VPS)
      6.  Геолокация IP (страна, город, организация)
      7.  DNS-конфигурация (не российские DNS)
      8.  WebRTC (инструкция к ручной проверке)
      9.  Claude Code — settings.json (~/.claude/settings.json)
      10. VS Code — settings.json (http.proxy)
      11. Cursor — settings.json (http.proxy + disableHttp2)
      12. Часовой пояс (соответствие стране VPS)
      13. Локаль / язык (не ru-RU)
      14. Сетевая доступность Anthropic API и VPS

    Скрипт НЕ ИЗМЕНЯЕТ конфигурацию. Только читает и проверяет.

.PARAMETER VPSIP
    IP-адрес вашего VPS. Если задан, скрипт проверит, что внешний IP через
    прокси совпадает с ним, а также проверит TCP-доступность VPS.

.PARAMETER ProxyPort
    Порт локального HTTP-прокси (v2rayN / Hiddify). По умолчанию 10809.
    Можно задать несколько через запятую: "10809,8080,7890".

.PARAMETER ExpectedCountry
    Ожидаемый код страны VPS (US, DE, NL, GB, FI). Если задан, скрипт
    проверит соответствие геолокации и часового пояса.

.PARAMETER Json
    Вывести результат в JSON (для автоматизации).

.PARAMETER SkipNetwork
    Пропустить сетевые проверки (быстрее, только локальные конфиги).

.PARAMETER SkipConfig
    Пропустить проверки конфигов инструментов.

.EXAMPLE
    .\verify-leaks.ps1
    Проверка с параметрами по умолчанию (порт 10809).

.EXAMPLE
    .\verify-leaks.ps1 -VPSIP 203.0.113.42 -ExpectedCountry DE
    Полная проверка с валидацией IP и страны.

.EXAMPLE
    .\verify-leaks.ps1 -ProxyPort 10808,10809 -Json > report.json
    Проверить несколько портов, вывод в JSON.

.NOTES
    Автор:  Claude AI VPS Setup Guide
    Версия: 1.0.0
    Лицензия: MIT

    ⚠️  Скрипт выполняет только чтение. Никакие настройки не меняются.
    ⚠️  Для полной проверки WebRTC и DNS-утечек требуется браузер
        (см. ссылки в выводе).
#>

[CmdletBinding()]
param(
    [string]$VPSIP,
    [string]$ProxyPort = "10809",
    [string]$ExpectedCountry,
    [switch]$Json,
    [switch]$SkipNetwork,
    [switch]$SkipConfig
)

# ==============================================================================
# Константы
# ==============================================================================
$Script:Version = "1.0.0"
$Script:ScriptName = "verify-leaks.ps1"

# Цвета (только если интерактивный терминал)
if ($Host.Name -eq "ConsoleHost" -and -not $Json) {
    $Script:C = @{
        Red    = "`e[31m"
        Green  = "`e[32m"
        Yellow = "`e[33m"
        Blue   = "`e[34m"
        Cyan   = "`e[36m"
        Bold   = "`e[1m"
        NC     = "`e[0m"
    }
} else {
    $Script:C = @{
        Red = ""; Green = ""; Yellow = ""; Blue = ""; Cyan = ""; Bold = ""; NC = ""
    }
}

# Счётчики
$Script:Passed   = 0
$Script:Warnings = 0
$Script:Failures = 0
$Script:Results  = @()

# ==============================================================================
# Вспомогательные функции
# ==============================================================================
function Write-Section {
    param([string]$Title)
    if (-not $Json) {
        Write-Host ""
        Write-Host "$($C.Bold)$($C.Cyan)▶ $Title$($C.NC)"
    }
}

function Write-Pass {
    param([string]$Message, [string]$Category = "", [string]$Detail = "")
    $Script:Passed++
    $Script:Results += [pscustomobject]@{
        Status = "PASS"; Category = $Category; Message = $Message; Detail = $Detail
    }
    if (-not $Json) { Write-Host "  $($C.Green)[ OK ]$($C.NC)  $Message" }
}

function Write-Warn {
    param([string]$Message, [string]$Category = "", [string]$Detail = "")
    $Script:Warnings++
    $Script:Results += [pscustomobject]@{
        Status = "WARN"; Category = $Category; Message = $Message; Detail = $Detail
    }
    if (-not $Json) { Write-Host "  $($C.Yellow)[WARN]$($C.NC)  $Message" }
}

function Write-Fail {
    param([string]$Message, [string]$Category = "", [string]$Detail = "")
    $Script:Failures++
    $Script:Results += [pscustomobject]@{
        Status = "FAIL"; Category = $Category; Message = $Message; Detail = $Detail
    }
    if (-not $Json) { Write-Host "  $($C.Red)[FAIL]$($C.NC)  $Message" }
}

function Write-Info {
    param([string]$Message)
    if (-not $Json) { Write-Host "  $($C.Blue)[INFO]$($C.NC)  $Message" }
}

function Write-Detail {
    param([string]$Message)
    if (-not $Json -and $Verbose) { Write-Host "         $Message" -ForegroundColor DarkGray }
}

# HTTP-запрос с таймаутом (универсальная функция)
function Invoke-SafeWebRequest {
    param(
        [string]$Uri,
        [string]$Proxy = $null,
        [int]$TimeoutSec = 15,
        [switch]$UseBasicParsing
    )
    $args = @{
        Uri             = $Uri
        TimeoutSec      = $TimeoutSec
        UseBasicParsing = $true
        ErrorAction     = "Stop"
    }
    if ($Proxy) { $args.Proxy = $Proxy }

    try {
        return Invoke-WebRequest @args
    } catch {
        return $null
    }
}

# Проверка доступности порта
function Test-TcpPort {
    param(
        [string]$ComputerName,
        [int]$Port,
        [int]$TimeoutMs = 5000
    )
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        $wait = $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($wait -and $client.Connected) {
            $client.EndConnect($async)
            $client.Close()
            return $true
        }
        $client.Close()
        return $false
    } catch {
        return $false
    }
}

# Получить внешний IP (через прокси, если задан)
function Get-ExternalIP {
    param([string]$Proxy = $null)
    $providers = @(
        "https://api.ipify.org",
        "https://ifconfig.me/ip",
        "https://icanhazip.com",
        "https://ipinfo.io/ip"
    )
    foreach ($url in $providers) {
        $resp = Invoke-SafeWebRequest -Uri $url -Proxy $Proxy -TimeoutSec 10
        if ($resp -and $resp.Content) {
            $ip = $resp.Content.Trim()
            if ($ip -match '^(\d{1,3}\.){3}\d{1,3}$') {
                return $ip
            }
        }
    }
    return $null
}

# Получить геоинформацию по IP
function Get-GeoInfo {
    param([string]$IP)
    $resp = Invoke-SafeWebRequest -Uri "https://ipinfo.io/$IP/json" -TimeoutSec 15
    if ($resp -and $resp.Content) {
        try {
            return $resp.Content | ConvertFrom-Json
        } catch {
            return $null
        }
    }
    return $null
}

# ==============================================================================
# Заголовок
# ==============================================================================
if (-not $Json) {
    Write-Host ""
    Write-Host "$($C.Bold)$($C.Cyan)╔════════════════════════════════════════════════════════════╗$($C.NC)"
    Write-Host "$($C.Bold)$($C.Cyan)║        verify-leaks.ps1 — проверка утечек для Claude      ║$($C.NC)"
    Write-Host "$($C.Bold)$($C.Cyan)╚════════════════════════════════════════════════════════════╝$($C.NC)"
    Write-Host ""
    Write-Host "  Версия:       $Script:Version"
    Write-Host "  Дата/время:   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host "  VPS IP:       $(if ($VPSIP) { $VPSIP } else { '(не задан)' })"
    Write-Host "  Прокси-порт:  $ProxyPort"
    Write-Host "  Ожид. страна: $(if ($ExpectedCountry) { $ExpectedCountry } else { '(не задана)' })"
}

# ==============================================================================
# 1. Окружение
# ==============================================================================
Write-Section "1. Окружение"

$psVersion = $PSVersionTable.PSVersion
Write-Info "PowerShell: $psVersion"
if ($psVersion.Major -ge 5) {
    Write-Pass "PowerShell версия $($psVersion.Major).$($psVersion.Minor) поддерживается" "env"
} else {
    Write-Fail "PowerShell $psVersion слишком старый. Требуется 5.1+" "env"
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    Write-Info "Права: Администратор"
} else {
    Write-Info "Права: Пользователь (некоторые проверки могут быть недоступны)"
}

$osVersion = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
Write-Info "ОС: $osVersion"

# ==============================================================================
# 2. Системный прокси (реестр Windows)
# ==============================================================================
Write-Section "2. Системный прокси (реестр Windows)"

$regKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
try {
    $reg = Get-ItemProperty -Path $regKey -ErrorAction Stop
    $proxyEnable = $reg.ProxyEnable
    $proxyServer = $reg.ProxyServer
    $proxyOverride = $reg.ProxyOverride

    if ($proxyEnable -eq 1) {
        Write-Pass "Системный прокси включён: $proxyServer" "system-proxy" "$proxyServer"

        # Проверка, что порт совпадает с ожидаемым
        if ($proxyServer -match "127\.0\.0\.1:(\d+)") {
            $sysPort = $Matches[1]
            if ($ProxyPort.Split(",") -contains $sysPort) {
                Write-Pass "Порт системного прокси ($sysPort) совпадает с ожидаемым" "system-proxy"
            } else {
                Write-Warn "Порт системного прокси ($sysPort) не в списке ожидаемых ($ProxyPort)" "system-proxy"
            }
        }
        if ($proxyOverride) {
            Write-Info "Bypass list: $proxyOverride"
        }
    } else {
        Write-Warn "Системный прокси ВЫКЛЮЧЕН. Claude Desktop и часть приложений могут не работать" "system-proxy"
        Write-Info "Включите: v2rayN → Settings → System Proxy → Set system proxy"
    }
} catch {
    Write-Fail "Не удалось прочитать реестр: $_" "system-proxy"
}

# ==============================================================================
# 3. Переменные окружения
# ==============================================================================
Write-Section "3. Переменные окружения (HTTP_PROXY / HTTPS_PROXY / NO_PROXY)"

$envVars = @("HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY")
foreach ($var in $envVars) {
    $userVal = [Environment]::GetEnvironmentVariable($var, "User")
    $procVal = [Environment]::GetEnvironmentVariable($var, "Process")

    if ($procVal) {
        $effectiveVal = $procVal
        $scope = "Process"
    } elseif ($userVal) {
        $effectiveVal = $userVal
        $scope = "User"
    } else {
        $effectiveVal = $null
        $scope = "none"
    }

    if ($effectiveVal) {
        Write-Pass "$var = $effectiveVal (scope: $scope)" "env-vars" "$effectiveVal"
    } else {
        Write-Warn "$var не установлена" "env-vars"
    }
}

# Проверка NO_PROXY на localhost
$noProxy = [Environment]::GetEnvironmentVariable("NO_PROXY", "User")
if (-not $noProxy) { $noProxy = [Environment]::GetEnvironmentVariable("NO_PROXY", "Process") }
if ($noProxy) {
    if ($noProxy -match "localhost" -and $noProxy -match "127\.0\.0\.1") {
        Write-Pass "NO_PROXY содержит localhost и 127.0.0.1 (OAuth-callback не сломается)" "env-vars"
    } else {
        Write-Warn "NO_PROXY не содержит localhost и/или 127.0.0.1 — OAuth может сломаться" "env-vars"
    }
}

# ==============================================================================
# 4. Доступность локального прокси
# ==============================================================================
Write-Section "4. Доступность локального прокси"

$workingProxies = @()
$ports = $ProxyPort.Split(",") | ForEach-Object { $_.Trim() }

foreach ($port in $ports) {
    if ($port -match '^\d+$') {
        if (Test-TcpPort -ComputerName "127.0.0.1" -Port ([int]$port)) {
            Write-Pass "Порт 127.0.0.1:$port открыт — прокси слушает" "proxy-port" "127.0.0.1:$port"
            $workingProxies += $port
        } else {
            Write-Warn "Порт 127.0.0.1:$port закрыт — прокси не запущен или не слушает" "proxy-port"
        }
    }
}

if ($workingProxies.Count -eq 0) {
    Write-Fail "Ни один прокси-порт недоступен. Запустите v2rayN / Hiddify" "proxy-port"
}

$primaryProxy = if ($workingProxies.Count -gt 0) { "http://127.0.0.1:$($workingProxies[0])" } else { $null }

# ==============================================================================
# 5. Внешний IP
# ==============================================================================
if (-not $SkipNetwork -and $primaryProxy) {
    Write-Section "5. Внешний IP через прокси"

    $extIP = Get-ExternalIP -Proxy $primaryProxy
    if ($extIP) {
        Write-Pass "Внешний IP через прокси: $extIP" "external-ip" $extIP

        if ($VPSIP) {
            if ($extIP -eq $VPSIP) {
                Write-Pass "Внешний IP совпадает с IP VPS ($VPSIP)" "external-ip"
            } else {
                Write-Fail "Внешний IP ($extIP) НЕ совпадает с VPSIP ($VPSIP)" "external-ip"
                Write-Info "Проверьте: активен ли сервер в v2rayN, работает ли VLESS на VPS"
            }
        }
    } else {
        Write-Fail "Не удалось получить внешний IP через прокси $primaryProxy" "external-ip"
    }
} elseif ($SkipNetwork) {
    Write-Info "Пропущено (--SkipNetwork)"
} else {
    Write-Warn "Пропущено — нет рабочего прокси" "external-ip"
}

# ==============================================================================
# 6. Геолокация IP
# ==============================================================================
if (-not $SkipNetwork -and $extIP) {
    Write-Section "6. Геолокация IP"

    $geo = Get-GeoInfo -IP $extIP
    if ($geo) {
        Write-Info "IP:        $($geo.ip)"
        Write-Info "Hostname:  $($geo.hostname)"
        Write-Info "Город:     $($geo.city), $($geo.region), $($geo.country)"
        Write-Info "Org:       $($geo.org)"
        Write-Info "Timezone:  $($geo.timezone)"

        # Проверка страны
        $countryCode = $geo.country
        $supportedCountries = @("US", "DE", "NL", "GB", "CA", "FR", "FI", "SE", "CH", "AT", "IE", "AU", "JP", "SG")
        $forbiddenCountries = @("RU", "BY", "IR", "KP", "SY", "CU")

        if ($forbiddenCountries -contains $countryCode) {
            Write-Fail "Страна $countryCode не поддерживается Anthropic" "geolocation"
        } elseif ($supportedCountries -contains $countryCode) {
            Write-Pass "Страна $countryCode поддерживается Anthropic" "geolocation"
        } else {
            Write-Warn "Страна $countryCode не в списке рекомендованных" "geolocation"
        }

        # Проверка ожидаемой страны
        if ($ExpectedCountry -and $countryCode -ne $ExpectedCountry) {
            Write-Fail "Ожидалась страна $ExpectedCountry, получена $countryCode" "geolocation"
        }

        # Проверка, что организация — хостинг
        if ($geo.org -match "(hosting|datacenter|cloud|vps|server|ovh|hetzner|digitalocean|vultr|linode|contabo)") {
            Write-Pass "Организация определяется как хостинг — нормально для VPS" "geolocation"
        }
    } else {
        Write-Fail "Не удалось получить геоинформацию для $extIP" "geolocation"
    }
} elseif (-not $SkipNetwork) {
    Write-Warn "Пропущено — нет внешнего IP" "geolocation"
}

# ==============================================================================
# 7. DNS-конфигурация
# ==============================================================================
Write-Section "7. DNS-конфигурация"

try {
    $dnsServers = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.ServerAddresses } |
        Select-Object -ExpandProperty ServerAddresses -Unique

    if ($dnsServers) {
        Write-Info "Системные DNS: $($dnsServers -join ', ')"

        $russianDNS = @("77.88.8.8", "77.88.8.1", "77.88.8.7")  # Яндекс DNS
        $hasRussian = $false
        foreach ($dns in $dnsServers) {
            if ($russianDNS -contains $dns) { $hasRussian = $true }
            # Российские провайдерские диапазоны (пример: Ростелеком)
            if ($dns -match "^213\.180\." -or $dns -match "^81\.19\." -or $dns -match "^212\.188\.") {
                $hasRussian = $true
            }
        }

        if ($hasRussian) {
            Write-Warn "Обнаружены российские DNS в системной конфигурации" "dns"
            Write-Info "Включите Remote DNS в v2rayN (Settings → DNS → Remote DNS = 1.1.1.1)"
        } else {
            Write-Pass "Системные DNS не российские" "dns"
        }
    } else {
        Write-Warn "Не удалось прочитать системные DNS" "dns"
    }
} catch {
    Write-Warn "Ошибка при чтении DNS: $_" "dns"
}

# Тест DNS-резолвинга
try {
    $resolve = Resolve-DnsName -Name "api.anthropic.com" -Type A -ErrorAction Stop -DnsOnly
    if ($resolve | Where-Object { $_.IPAddress }) {
        $ips = ($resolve | Where-Object { $_.IPAddress } | Select-Object -First 2 -ExpandProperty IPAddress) -join ", "
        Write-Pass "DNS-резолвинг api.anthropic.com работает: $ips" "dns"
    }
} catch {
    Write-Warn "DNS-резолвинг api.anthropic.com не удался: $_" "dns"
}

Write-Info "💡 Для полной проверки DNS-утечек откройте в Dolphin-профиле: https://ipleak.net"

# ==============================================================================
# 8. WebRTC (инструкция)
# ==============================================================================
Write-Section "8. WebRTC (ручная проверка)"

Write-Info "WebRTC нельзя проверить из PowerShell — нужен браузер."
Write-Info "Откройте в Dolphin-профиле: https://browserleaks.com/webrtc"
Write-Info "Ожидаемо: Public IP отсутствует ИЛИ совпадает с IP VPS"
Write-Info "🚨 Российский публичный IP = провал. Установите WebRTC = Disabled в Dolphin."

# ==============================================================================
# 9. Claude Code — settings.json
# ==============================================================================
if (-not $SkipConfig) {
    Write-Section "9. Claude Code — settings.json"

    $claudeSettings = Join-Path $env:USERPROFILE ".claude\settings.json"
    if (Test-Path $claudeSettings) {
        Write-Pass "Файл существует: $claudeSettings" "claude-code"
        try {
            $cc = Get-Content $claudeSettings -Raw | ConvertFrom-Json
            if ($cc.env -and $cc.env.HTTPS_PROXY) {
                Write-Pass "HTTPS_PROXY в settings.json: $($cc.env.HTTPS_PROXY)" "claude-code"
            } else {
                Write-Warn "HTTPS_PROXY не задан в env-блоке settings.json" "claude-code"
            }
            if ($cc.env -and $cc.env.NO_PROXY -and $cc.env.NO_PROXY -match "127\.0\.0\.1") {
                Write-Pass "NO_PROXY содержит 127.0.0.1" "claude-code"
            } else {
                Write-Warn "NO_PROXY не содержит 127.0.0.1 — OAuth может сломаться" "claude-code"
            }
        } catch {
            Write-Warn "Не удалось распарсить settings.json: $_" "claude-code"
        }
    } else {
        Write-Warn "Не найден $claudeSettings" "claude-code"
        Write-Info "Создайте по инструкции tools-setup.md (шаг 3.2.3)"
    }

    # Проверка, что claude CLI доступен
    $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($claudeCmd) {
        Write-Pass "CLI 'claude' доступен: $($claudeCmd.Source)" "claude-code"
    } else {
        Write-Info "CLI 'claude' не в PATH (не критично, если используется только Desktop)"
    }
}

# ==============================================================================
# 10. VS Code — settings.json
# ==============================================================================
if (-not $SkipConfig) {
    Write-Section "10. VS Code — settings.json"

    $vscodePaths = @(
        (Join-Path $env:APPDATA "Code\User\settings.json"),
        (Join-Path $env:USERPROFILE ".config\Code\User\settings.json")
    )
    $vscodeFound = $false

    foreach ($path in $vscodePaths) {
        if (Test-Path $path) {
            $vscodeFound = $true
            Write-Pass "Найден: $path" "vscode"
            try {
                $vs = Get-Content $path -Raw | ConvertFrom-Json
                if ($vs.'http.proxy') {
                    Write-Pass "http.proxy = $($vs.'http.proxy')" "vscode"
                } else {
                    Write-Warn "http.proxy не задан" "vscode"
                }
                if ($vs.'http.proxySupport') {
                    Write-Info "http.proxySupport = $($vs.'http.proxySupport')"
                }
            } catch {
                Write-Warn "Не удалось распарсить $path : $_" "vscode"
            }
            break
        }
    }

    if (-not $vscodeFound) {
        Write-Info "VS Code не установлен или settings.json не найден"
    }
}

# ==============================================================================
# 11. Cursor — settings.json
# ==============================================================================
if (-not $SkipConfig) {
    Write-Section "11. Cursor — settings.json"

    $cursorPath = Join-Path $env:APPDATA "Cursor\User\settings.json"
    if (Test-Path $cursorPath) {
        Write-Pass "Найден: $cursorPath" "cursor"
        try {
            $cu = Get-Content $cursorPath -Raw | ConvertFrom-Json
            if ($cu.'http.proxy') {
                Write-Pass "http.proxy = $($cu.'http.proxy')" "cursor"
            } else {
                Write-Warn "http.proxy не задан" "cursor"
            }
            if ($cu.'cursor.general.disableHttp2' -eq $true) {
                Write-Pass "cursor.general.disableHttp2 = true (критично для стриминга)" "cursor"
            } else {
                Write-Fail "cursor.general.disableHttp2 НЕ включён — стриминг может зависать" "cursor"
                Write-Info "Добавьте: `"cursor.general.disableHttp2`": true"
            }
        } catch {
            Write-Warn "Не удалось распарсить $cursorPath : $_" "cursor"
        }
    } else {
        Write-Info "Cursor не установлен или settings.json не найден"
    }
}

# ==============================================================================
# 12. Часовой пояс
# ==============================================================================
Write-Section "12. Часовой пояс"

$tz = (Get-TimeZone).Id
$tzOffset = (Get-TimeZone).BaseUtcOffset
Write-Info "Текущий часовой пояс: $tz (UTC$($tzOffset.ToString('hh\:mm')))"

# Маппинг стран на ожидаемые часовые пояса
$tzMap = @{
    "US" = @("Eastern Standard Time", "Central Standard Time", "Mountain Standard Time", "Pacific Standard Time")
    "DE" = @("W. Europe Standard Time", "Central European Standard Time")
    "NL" = @("W. Europe Standard Time")
    "GB" = @("GMT Standard Time")
    "FI" = @("FLE Standard Time")
}

if ($ExpectedCountry -and $tzMap.ContainsKey($ExpectedCountry)) {
    if ($tzMap[$ExpectedCountry] -contains $tz) {
        Write-Pass "Часовой пояс соответствует стране $ExpectedCountry" "timezone"
    } else {
        Write-Warn "Часовой пояс ($tz) не соответствует ожидаемому для $ExpectedCountry" "timezone"
        Write-Info "Рекомендуется: $($tzMap[$ExpectedCountry] -join ' или ')"
    }
} elseif ($tz -match "Russian|RTZ") {
    Write-Warn "Часовой пояс российский ($tz), но IP не российский — потенциальный сигнал антифроду" "timezone"
    Write-Info "Установите: Settings → Time & Language → Date & Time → Time zone"
} else {
    Write-Info "Часовой пояс не российский — OK"
}

# ==============================================================================
# 13. Локаль / язык
# ==============================================================================
Write-Section "13. Локаль / язык"

$uiCulture = (Get-UICulture).Name
$culture = (Get-Culture).Name
Write-Info "UI Culture: $uiCulture"
Write-Info "Culture:    $culture"

if ($uiCulture -match "^ru" -or $culture -match "^ru") {
    Write-Warn "Российская локаль ($uiCulture / $culture)" "locale"
    Write-Info "Рекомендуется: Settings → Time & Language → Language & Region → Windows display language = English"
} else {
    Write-Pass "Локаль не российская" "locale"
}

# ==============================================================================
# 14. Сетевая доступность Anthropic и VPS
# ==============================================================================
if (-not $SkipNetwork -and $primaryProxy) {
    Write-Section "14. Сетевая доступность"

    # Тест api.anthropic.com через прокси
    $apiResp = Invoke-SafeWebRequest -Uri "https://api.anthropic.com/v1/messages" -Proxy $primaryProxy -TimeoutSec 15
    if ($apiResp) {
        Write-Pass "api.anthropic.com доступен через прокси (HTTP $($apiResp.StatusCode))" "network"
    } else {
        # Ожидаем 401/403 — это нормально, соединение установлено
        try {
            $resp = Invoke-WebRequest -Uri "https://api.anthropic.com/v1/messages" -Proxy $primaryProxy `
                -Method Head -TimeoutSec 15 -SkipHttpErrorCheck -ErrorAction Stop
            if ($resp.StatusCode -in @(401, 403, 404)) {
                Write-Pass "api.anthropic.com доступен (HTTP $($resp.StatusCode) — норма без токена)" "network"
            }
        } catch {
            Write-Fail "api.anthropic.com недоступен через прокси: $_" "network"
        }
    }

    # Тест claude.ai через прокси
    $claudeResp = Invoke-SafeWebRequest -Uri "https://claude.ai" -Proxy $primaryProxy -TimeoutSec 15
    if ($claudeResp -and $claudeResp.StatusCode -eq 200) {
        Write-Pass "claude.ai доступен через прокси" "network"
    } else {
        Write-Warn "claude.ai не вернул 200 (возможно, редирект — проверьте в браузере)" "network"
    }

    # Тест VPS
    if ($VPSIP) {
        if (Test-TcpPort -ComputerName $VPSIP -Port 443) {
            Write-Pass "VPS $VPSIP:443 доступен (TCP)" "network"
        } else {
            Write-Fail "VPS $VPSIP:443 недоступен — VLESS не работает" "network"
        }

        # Ping
        $ping = Test-Connection -ComputerName $VPSIP -Count 4 -ErrorAction SilentlyContinue
        if ($ping) {
            $avgPing = [math]::Round(($ping | Measure-Object -Property ResponseTime -Average).Average, 0)
            Write-Info "Ping до VPS: $avgPing ms"
            if ($avgPing -gt 300) {
                Write-Warn "Ping > 300 ms — возможны проблемы со стримингом" "network"
            } elseif ($avgPing -gt 200) {
                Write-Info "Ping > 200 ms — приемлемо, но не идеально"
            } else {
                Write-Pass "Ping в норме (< 200 ms)" "network"
            }
        }
    }
}

# ==============================================================================
# Итог
# ==============================================================================
Write-Section "📊 Итог"

$total = $Script:Passed + $Script:Warnings + $Script:Failures
$exitCode = 0

if ($Json) {
    $report = [pscustomobject]@{
        script    = $Script:ScriptName
        version   = $Script:Version
        timestamp = (Get-Date -Format 'o')
        vpsIP     = $VPSIP
        proxyPort = $ProxyPort
        country   = $ExpectedCountry
        summary   = [pscustomobject]@{
            total    = $total
            passed   = $Script:Passed
            warnings = $Script:Warnings
            failures = $Script:Failures
            result   = if ($Script:Failures -gt 0) { "fail" } elseif ($Script:Warnings -gt 0) { "warn" } else { "ok" }
        }
        checks    = $Script:Results
    }
    $report | ConvertTo-Json -Depth 5
} else {
    Write-Host "  Всего проверок:  $total"
    Write-Host "  $($C.Green)Пройдено:$($C.NC)       $Script:Passed"
    Write-Host "  $($C.Yellow)Предупреждений:$($C.NC) $Script:Warnings"
    Write-Host "  $($C.Red)Провалено:$($C.NC)      $Script:Failures"
    Write-Host ""

    if ($Script:Failures -gt 0) {
        Write-Host "$($C.Red)$($C.Bold)❌ Обнаружены критические проблемы.$($C.NC)"
        Write-Host "   Исправьте все FAIL-пункты перед входом в Claude."
        $exitCode = 2
    } elseif ($Script:Warnings -gt 0) {
        Write-Host "$($C.Yellow)$($C.Bold)⚠️  Есть предупреждения.$($C.NC)"
        Write-Host "   Просмотрите WARN-пункты — часть из них критична для консистентности."
        $exitCode = 1
    } else {
        Write-Host "$($C.Green)$($C.Bold)✅ Все проверки пройдены.$($C.NC)"
        Write-Host "   ПК готов к работе с Claude AI."
        $exitCode = 0
    }

    Write-Host ""
    Write-Host "  📌 Не забудьте проверить вручную:"
    Write-Host "     • https://ipleak.net — IP, DNS, WebRTC в Dolphin-профиле"
    Write-Host "     • https://browserleaks.com/javascript — timezone / language"
    Write-Host "     • https://browserleaks.com/webrtc — WebRTC public IP"
    Write-Host "     • https://scamalytics.com/ip/<IP_VPS> — Fraud Score"
    Write-Host ""
}

exit $exitCode
