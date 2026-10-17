<# : -------- запуск из Windows: этот блок выполняет cmd, PowerShell его пропускает --------
@echo off
chcp 65001 >nul
set "Z2K_SELF=%~f0"
set "Z2K_ARGS=%*"
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ([IO.File]::ReadAllText($env:Z2K_SELF, (New-Object Text.UTF8Encoding $false)))"
echo.
pause
goto :eof
#>
# ============================================================================
#  z2k-tool — проверка доменов автоподбора z2k и подбор стратегий
#
#  1. Выгружает с роутера все строки автоподбора (как вкладка «Автоподбор»).
#  2. Проверяет каждый домен МИМО обхода (роутер сам стучится к сайту):
#     блокирует ли его провайдер или замедляет.
#  3. Раскладывает домены на два списка: блокируемые и не блокируемые.
#  4. Предлагает: не блокируемые — в «Исключения» z2k;
#     блокируемые — подобрать стратегию с заморозкой:
#        а) короткий подбор: первая подошедшая стратегия;
#        б) длинный подбор: все стратегии, замораживается лучшая.
#
#  Строки, для которых стратегия не нашлась, запоминаются в z2k-recheck.tsv
#  рядом с программой. Перепроверить их: пункт [5] меню или z2k-recheck.bat.
#
#  Все результаты — в папке z2k-ГГГГММДД-ЧЧММ рядом с этим файлом.
#  Роутер меняется только в шаге 4 и только после вашего подтверждения.
# ============================================================================

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$Host.UI.RawUI.WindowTitle = "z2k-tool"

$Self    = if ($env:Z2K_SELF) { $env:Z2K_SELF } else { $PSCommandPath }
$BaseDir = Split-Path -Parent $Self
$IniFile = Join-Path $BaseDir "z2k-tool.ini"
$inv     = [Globalization.CultureInfo]::InvariantCulture

# ---- настройки подбора ----
$Cfg = @{
    Router = "192.168.7.1"; Port = 8088
    Timeout = 7; Settle = 3                       # таймаут запроса и пауза после смены стратегии, с
    ShortTries = 5; ShortConfirm = 10; ShortConfirmMaxFail = 1
    LongTries = 6; LongMaxFail = 2; Finalists = 3; FinalTries = 15; MinRate = 0.9
}
if (Test-Path $IniFile) {
    foreach ($l in Get-Content -LiteralPath $IniFile -Encoding UTF8) {
        if ($l -match '^\s*(\w+)\s*=\s*(.+?)\s*$' -and $Cfg.ContainsKey($Matches[1])) {
            $k = $Matches[1]; $v = $Matches[2]
            $Cfg[$k] = if ($v -match '^\d+(\.\d+)?$') { [double]$v } else { $v }
        }
    }
}

# Для «корневых» доменов CDN по самому имени ничего не отвечает — проверяем
# реальный хост, который ходит под этим доменом.
$KnownHost = @{
    "googleapis.com" = "youtubei.googleapis.com"; "googlevideo.com" = "redirector.googlevideo.com"
    "ggpht.com" = "yt3.ggpht.com"; "ytimg.com" = "i.ytimg.com"; "googleusercontent.com" = "lh3.googleusercontent.com"
    "gvt1.com" = "redirector.gvt1.com"; "fbcdn.net" = "static.xx.fbcdn.net"; "cdninstagram.com" = "static.cdninstagram.com"
    "whatsapp.net" = "mmg.whatsapp.net"; "amazonaws.com" = "s3.amazonaws.com"; "jsdelivr.net" = "cdn.jsdelivr.net"
    "doubleclick.net" = "ad.doubleclick.net"; "live.net" = "login.live.net"; "discordapp.net" = "media.discordapp.net"
}
$PublicSuffix = @("co.uk", "com.au", "com.br", "co.jp", "com.tr", "co.in", "com.ua", "co.kr", "com.cn", "org.uk", "co.za", "com.mx")
# Домены, от которых зависят YouTube/Google/мессенджеры: в исключения — только осознанно.
$Important = 'youtube|googlevideo|googleapis|ytimg|ggpht|gstatic|google|gvt1|telegram|discord|whatsapp|instagram|cdninstagram|facebook|fbcdn'

# ============================================================================
#  ОБЩЕЕ
# ============================================================================
function Say([string]$t, [string]$c = "Gray") { Write-Host $t -ForegroundColor $c }
function Head([string]$t) { Write-Host ""; Write-Host ("=" * 70) -ForegroundColor DarkCyan; Write-Host "  $t" -ForegroundColor Cyan; Write-Host ("=" * 70) -ForegroundColor DarkCyan }
function Ask([string]$q) { Write-Host -NoNewline "$q " -ForegroundColor White; return (Read-Host).Trim() }
function Write-Lines([string]$path, $lines) {
    # UTF-8 с BOM — чтобы Excel и Блокнот открывали кириллицу правильно
    [IO.File]::WriteAllLines($path, [string[]]@($lines), (New-Object Text.UTF8Encoding $true))
}
function Add-Line([string]$path, [string]$line) {
    if (-not (Test-Path $path)) { Write-Lines $path @() }
    [IO.File]::AppendAllText($path, "$line`r`n", (New-Object Text.UTF8Encoding $false))
}

function Save-Ini {
    # адрес и порт запоминаются; остальные строки файла (если вы их дописали) сохраняются
    $keep = @()
    if (Test-Path $IniFile) { $keep = @(Get-Content -LiteralPath $IniFile -Encoding UTF8 | Where-Object { $_ -notmatch '^\s*(Router|Port)\s*=' }) }
    [IO.File]::WriteAllLines($IniFile, [string[]](@("Router=$($Cfg.Router)", "Port=$([int]$Cfg.Port)") + $keep), (New-Object Text.UTF8Encoding $false))
}
$RecheckFile = Join-Path $BaseDir "z2k-recheck.tsv"
function Read-Recheck {
    $rows = @()
    if (-not (Test-Path $RecheckFile)) { return $rows }
    foreach ($l in Get-Content -LiteralPath $RecheckFile -Encoding UTF8) {
        $c = $l -split "`t"
        if ($c.Count -lt 4 -or $c[0] -eq "пул") { continue }
        $rows += [pscustomobject]@{ Pool = $c[0]; HostKey = $c[1]; Domain = $c[2]; Url = $c[3]
                                    Ip = ($c[1] -split "\|")[1]; Quic = ($c[0] -eq "quic")
                                    Note = $(if ($c.Count -ge 6) { $c[5] } else { "" }) }
    }
    return $rows
}
function Save-Recheck($rows) {
    if (-not @($rows).Count) { if (Test-Path $RecheckFile) { Remove-Item -LiteralPath $RecheckFile -Force }; return }
    $lines = @("пул`tхост`tдомен`tадрес проверки`tкогда`tпочему")
    foreach ($r in $rows) { $lines += "$($r.Pool)`t$($r.HostKey)`t$($r.Domain)`t$($r.Url)`t$(Get-Date -Format 'yyyy-MM-dd HH:mm')`t$($r.Note)" }
    Write-Lines $RecheckFile $lines
}
function Api { "http://$($Cfg.Router):$([int]$Cfg.Port)/cgi-bin/api" }
function Invoke-Panel([string]$Method, [string]$Path, [hashtable]$Form = @{}, [int]$MaxTime = 15) {
    $a = @("-s", "-m", "$MaxTime", "-H", "X-Z2K-Panel: 1", "-w", "`n%{http_code}")
    if ($Method -eq "POST") {
        $a += @("-X", "POST")
        foreach ($k in $Form.Keys) { $a += @("--data-urlencode", "$k=$($Form[$k])") }
    }
    $out = & curl.exe @a "$(Api)$Path" 2>$null
    $lines = @($out -split "`n")
    $code = $lines[-1].Trim()
    $body = if ($lines.Count -gt 1) { ($lines[0..($lines.Count - 2)] -join "`n") } else { "" }
    if ($code -eq "401") { throw "Панель просит пароль. Выключите вход по паролю (меню z2k [P] -> [6]) на время работы." }
    if ($code -ne "200") {
        $msg = $body; try { $msg = ($body | ConvertFrom-Json).error } catch {}
        throw "панель ответила $code на $Path : $msg"
    }
    return $body
}
function Get-State { @((Invoke-Panel "GET" "/state" | ConvertFrom-Json).entries) }

# ============================================================================
#  ПОДКЛЮЧЕНИЕ К ПАНЕЛИ
# ============================================================================
function Connect-Panel {
    while ($true) {
        try {
            $p = Invoke-Panel "GET" "/pools" | ConvertFrom-Json
            $script:Pools = @{}
            foreach ($x in $p.pools.PSObject.Properties) { $script:Pools[$x.Name] = [int]$x.Value }
            Say ("Панель z2k: $(Api)  |  пулы: " + (($script:Pools.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ", ")) "DarkGray"
            Save-Ini
            return
        } catch {
            Say "Не удалось подключиться к панели $(Api): $_" "Red"
            $r = Ask "Адрес роутера (Enter — выход) [$($Cfg.Router)]:"
            if (-not $r) { exit 1 }
            if ($r -match '^(.+?):(\d+)$') { $Cfg.Router = $Matches[1]; $Cfg.Port = [int]$Matches[2] } else { $Cfg.Router = $r }
        }
    }
}

# ============================================================================
#  ШАГ 1: ВЫГРУЗКА
# ============================================================================
function Export-State {
    Head "ШАГ 1. Выгрузка списка автоподбора"
    $state = Get-State
    $order = @{ "yt_tcp" = 0; "gv_tcp" = 1; "rkn_tcp" = 2; "http_rkn" = 3; "quic" = 4 }
    $state = @($state | Sort-Object @{e = { if ($order.ContainsKey($_.key)) { $order[$_.key] } else { 9 } } }, @{e = { $_.host } })
    $lines = @("пул`tдомен`tIP`tстратегия`tрежим`tс какого времени")
    foreach ($e in $state) {
        $d, $ip = $e.host -split "\|", 2
        $t = [DateTimeOffset]::FromUnixTimeSeconds([long]$e.ts).ToLocalTime().ToString("yyyy-MM-dd HH:mm")
        $m = if ($e.mode -eq "frozen") { "заморожена" } else { "авто" }
        $lines += "$($e.key)`t$d`tIPv$ip`t$($e.strategy)`t$m`t$t"
    }
    Write-Lines (Join-Path $RunDir "1-autopodbor-full.tsv") $lines
    $doms = @($state | ForEach-Object { ($_.host -split "\|")[0] } | Select-Object -Unique)
    Say ("Строк автоподбора: {0}, доменов: {1}, заморожено: {2}" -f $state.Count, $doms.Count, @($state | Where-Object { $_.mode -eq "frozen" }).Count) "Green"
    Say "Сохранено: 1-autopodbor-full.tsv"
    return $state
}

# ============================================================================
#  ШАГ 2: ПРОВЕРКА БЕЗ ОБХОДА
# ============================================================================
function Invoke-Probe([string]$TestHost) {
    try {
        $j = Invoke-Panel "POST" "/diag/probe" @{ domain = $TestHost } 30 | ConvertFrom-Json
        $rep = [string]$j.report
    } catch {
        $k = if ("$_" -match "503") { "nomodule" } else { "unknown" }
        return [pscustomobject]@{ Kind = $k; Code = ""; Probe = ""; Report = "$_" }
    }
    $probe = ([regex]::Match($rep, "Probe:\s+(.+?)\s+\(")).Groups[1].Value
    $code  = ([regex]::Match($rep, "Code:\s+(\S+)")).Groups[1].Value
    $v     = ([regex]::Match($rep, "Verdict:\s+([A-Z]+)")).Groups[1].Value
    $kind = "unknown"
    if ($v -eq "HOT") { $kind = if ($code -match "cutoff|stall|slow|partial|16|truncat") { "slow" } else { "blocked" } }
    elseif ($v -eq "WATCH") { $kind = "ipblock" }
    elseif ($v -eq "IGNORE") {
        if ($probe -match "DNS=fail") { $kind = "nodns" }
        elseif ($rep -match "server-side") { $kind = "server" }
        else { $kind = "open" }
    }
    return [pscustomobject]@{ Kind = $kind; Code = $code; Probe = $probe; Report = $rep }
}
$KindText = @{
    blocked = "БЛОКИРУЕТСЯ"; slow = "ЗАМЕДЛЯЕТСЯ (обрыв на передаче)"; open = "открывается без обхода"
    ipblock = "блок по IP — стратегия не поможет"; nodns = "имя не резолвится"; server = "сервер отказывает сам (не DPI)"
    zone = "доменная зона, не сайт"; unknown = "проверить не удалось"
}

function Test-Domains($state) {
    Head "ШАГ 2. Проверка доменов без обхода"
    Say "Роутер обращается к каждому сайту мимо z2k — так видно, что делает провайдер." "DarkGray"
    Say "На роутере ничего не меняется. Примерно 3–20 с на домен.`n" "DarkGray"
    $doms = @($state | ForEach-Object { ($_.host -split "\|")[0] } | Select-Object -Unique)
    $res = [ordered]@{}
    $i = 0
    foreach ($d in $doms) {
        $i++
        if ($PublicSuffix -contains $d) {
            $r = [pscustomobject]@{ Domain = $d; TestHost = $d; Kind = "zone"; Code = ""; Probe = "" }
        } else {
            $h = if ($KnownHost.ContainsKey($d)) { $KnownHost[$d] } else { $d }
            $p = Invoke-Probe $h
            if ($p.Kind -eq "nomodule") {
                Say "`nНа роутере нет модуля проверки (z2k-detect). Переустановите z2k или включите его в меню [Y]." "Red"
                return $null
            }
            if ($p.Kind -eq "nodns" -and -not $KnownHost.ContainsKey($d)) {
                $p2 = Invoke-Probe "www.$d"
                if ($p2.Kind -notin @("nodns", "unknown")) { $p = $p2; $h = "www.$d" }
            }
            $r = [pscustomobject]@{ Domain = $d; TestHost = $h; Kind = $p.Kind; Code = $p.Code; Probe = $p.Probe }
        }
        $res[$d] = $r
        $col = switch ($r.Kind) { "blocked" { "Yellow" } "slow" { "Yellow" } "open" { "Green" } "unknown" { "DarkGray" } default { "DarkYellow" } }
        Write-Host ("  [{0,3}/{1}] {2,-30} {3}" -f $i, $doms.Count, $r.TestHost, $KindText[$r.Kind]) -ForegroundColor $col
    }

    # ---- ШАГ 3: два списка ----
    Head "ШАГ 3. Списки"
    $blocked = @($res.Values | Where-Object { $_.Kind -in @("blocked", "slow") })
    $open    = @($res.Values | Where-Object { $_.Kind -eq "open" })
    $other   = @($res.Values | Where-Object { $_.Kind -notin @("blocked", "slow", "open") })
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm"
    Write-Lines (Join-Path $RunDir "3-blocked.txt")     (@("# Блокируются или замедляются провайдером (проверка $stamp)") + @($blocked | ForEach-Object { $_.Domain }))
    Write-Lines (Join-Path $RunDir "3-not-blocked.txt") (@("# Открываются без обхода (проверка $stamp)") + @($open | ForEach-Object { $_.Domain }))
    $rep = @("домен`tчто проверяли`tитог`tкод`tстадии")
    foreach ($r in $res.Values) { $rep += "$($r.Domain)`t$($r.TestHost)`t$($KindText[$r.Kind])`t$($r.Code)`t$($r.Probe)" }
    Write-Lines (Join-Path $RunDir "2-check-report.tsv") $rep

    Say ("Блокируются / замедляются: {0}  -> 3-blocked.txt" -f $blocked.Count) "Yellow"
    Say ("Не блокируются:            {0}  -> 3-not-blocked.txt" -f $open.Count) "Green"
    if ($other.Count) {
        Say ("Прочее (IP-блок, нет DNS, зона, ошибка): {0}" -f $other.Count) "DarkYellow"
        foreach ($o in $other) { Say ("    {0,-28} {1}" -f $o.Domain, $KindText[$o.Kind]) "DarkYellow" }
    }
    Say "Подробный отчёт: 2-check-report.tsv"
    return $res
}

# ============================================================================
#  ШАГ 4а: ИСКЛЮЧЕНИЯ
# ============================================================================
function Select-Numbers([string]$s, [int]$max) {
    $set = New-Object System.Collections.Generic.List[int]
    foreach ($part in ($s -split "[,; ]+")) {
        if ($part -match '^(\d+)-(\d+)$') { for ($k = [int]$Matches[1]; $k -le [int]$Matches[2]; $k++) { if ($k -ge 1 -and $k -le $max -and -not $set.Contains($k)) { $set.Add($k) } } }
        elseif ($part -match '^\d+$') { $k = [int]$part; if ($k -ge 1 -and $k -le $max -and -not $set.Contains($k)) { $set.Add($k) } }
    }
    return $set
}

function Add-Exclusions($res) {
    Head "Добавить не блокируемые домены в «Исключения»"
    $open = @($res.Values | Where-Object { $_.Kind -eq "open" } | ForEach-Object { $_.Domain })
    if (-not $open.Count) { Say "Не блокируемых доменов нет."; return }
    Say "z2k перестанет обрабатывать эти домены совсем. Если провайдер заблокирует их позже," "DarkGray"
    Say "домен придётся убрать из исключений (панель -> «Исключения»). Помечены (!) домены," "DarkGray"
    Say "от которых зависят YouTube, Google и мессенджеры — их исключать стоит только осознанно.`n" "DarkGray"
    for ($k = 0; $k -lt $open.Count; $k++) {
        $mark = if ($open[$k] -match $Important) { " (!)" } else { "" }
        $c = if ($mark) { "Yellow" } else { "Gray" }
        Say ("  {0,3}. {1}{2}" -f ($k + 1), $open[$k], $mark) $c
    }
    $hasImp = @($open | Where-Object { $_ -match $Important }).Count -gt 0
    Say ""
    Say "  все   — добавить все" "White"
    if ($hasImp) { Say "  без!  — все, кроме помеченных (!)" "White" }
    Say "  1,3,5-7 — только выбранные номера" "White"
    Say "  Enter — ничего не добавлять" "White"
    $a = (Ask "Ваш выбор:").ToLower()
    $pick = @()
    if ($a -eq "все" -or $a -eq "all") { $pick = $open }
    elseif ($a -eq "без!" -or $a -eq "без") { $pick = @($open | Where-Object { $_ -notmatch $Important }) }
    elseif ($a) { $pick = @(Select-Numbers $a $open.Count | ForEach-Object { $open[$_ - 1] }) }
    if (-not $pick.Count) { Say "Ничего не добавлено."; return }

    $log = Join-Path $RunDir "4-exclusions.txt"
    $ok = 0
    foreach ($d in $pick) {
        try {
            Invoke-Panel "POST" "/whitelist/add" @{ domain = $d } | Out-Null
            Say "  + $d" "Green"; Add-Line $log "добавлен`t$d"; $ok++
        } catch {
            Say "  - $d : $_" "DarkYellow"; Add-Line $log "не добавлен`t$d`t$_"
        }
    }
    Say "Добавлено в исключения: $ok из $($pick.Count). Журнал: 4-exclusions.txt" "Green"
}

# ============================================================================
#  ШАГ 4б: ПОДБОР СТРАТЕГИЙ
# ============================================================================
$BlockPage = 'warning\.rt\.ru|blocked|blocklist|zapret|rkn\.gov|eais|/block|stop\.'
function Test-Once($Row) {
    $exe = if ($Row.Quic) { $script:Curl3 } else { "curl.exe" }
    $a = @("-s", "-k", "-o", "NUL", "-m", "$([int]$Cfg.Timeout)", "--connect-timeout", "4",
           "-w", "%{http_code}|%{time_total}|%{time_connect}|%{redirect_url}", "-$($Row.Ip)")
    if ($Row.Quic) { $a += "--http3-only" }
    $r = & $exe @a $Row.Url 2>$null
    $rc = $LASTEXITCODE
    $p = "$r".Trim() -split "\|", 4
    $t = 0.0
    if ($p.Count -ge 2) { [double]::TryParse($p[1], [Globalization.NumberStyles]::Float, $inv, [ref]$t) | Out-Null }
    $ok = ($rc -eq 0)
    if ($ok -and $p.Count -ge 4 -and $p[3] -and $p[3] -match $BlockPage) { $ok = $false }
    return [pscustomobject]@{ Ok = $ok; Time = $t }
}
function Test-Series($Row, [int]$N, [int]$Count, [int]$FailLimit, [string]$Label) {
    $ok = 0; $fail = 0; $times = @(); $line = ""
    for ($i = 1; $i -le $Count; $i++) {
        $r = Test-Once $Row
        if ($r.Ok) { $ok++; $times += $r.Time; $line += "+" } else { $fail++; $line += "x" }
        Write-Host -NoNewline ("`r    {0} {1,2}: {2,-16} " -f $Label, $N, $line)
        if ($fail -ge $FailLimit) { break }
    }
    $avg = if ($times.Count) { ($times | Measure-Object -Average).Average } else { 0 }
    $done = $ok + $fail
    Write-Host ("{0}/{1} {2}" -f $ok, $done, $(if ($times.Count) { "{0:N2} с" -f $avg } else { "" }))
    return [pscustomobject]@{ Strategy = $N; Ok = $ok; Done = $done; Rate = $ok / [math]::Max(1, $done); Avg = $avg }
}
function Set-Row($Row, [int]$N, [string]$Mode) {
    Invoke-Panel "POST" "/state/set" @{ key = $Row.Pool; host = $Row.HostKey; strategy = "$N"; mode = $Mode } | Out-Null
}

function Get-BlockedRows($state, $res) {
    # строки автоподбора для блокируемых доменов
    $blockedDoms = @($res.Values | Where-Object { $_.Kind -in @("blocked", "slow") })
    $rows = @()
    foreach ($b in $blockedDoms) {
        foreach ($e in @($state | Where-Object { ($_.host -split "\|")[0] -eq $b.Domain })) {
            $ip = ($e.host -split "\|")[1]
            $scheme = if ($e.key -like "http*") { "http" } else { "https" }
            $rows += [pscustomobject]@{ Pool = $e.key; HostKey = $e.host; Domain = $b.Domain; Ip = $ip
                                        Url = "${scheme}://$($b.TestHost)/"; Quic = ($e.key -eq "quic") }
        }
    }
    return $rows
}

function Find-Strategies($rows, [string]$Mode, [string]$Title = "") {
    $name = if ($Mode -eq "best") { "ДЛИННЫЙ подбор: все стратегии, замораживается лучшая" } else { "КОРОТКИЙ подбор: первая подошедшая стратегия" }
    if ($Title) { $name = "$Title — $name" }
    Head $name
    $rows = @($rows)
    if (-not $rows.Count) { Say "Подбирать нечего."; return }

    # оба подбора всегда идут по ВСЕМ блокируемым доменам
    $doms = @($rows | ForEach-Object { $_.Domain } | Select-Object -Unique)
    Say "К подбору: доменов $($doms.Count), строк автоподбора $($rows.Count)."
    if ($Mode -eq "best") {
        Say "Каждая строка проверяется на ВСЕХ стратегиях своего пула, лучшие — в финале." "DarkGray"
        foreach ($g in ($rows | Group-Object Pool | Sort-Object Name)) {
            Say ("    {0,-9} строк: {1,3}   стратегий в пуле: {2}" -f $g.Name, $g.Count, [int]$script:Pools[$g.Name]) "DarkGray"
        }
    }
    $quic = @($rows | Where-Object { $_.Quic })
    if ($quic.Count -and -not $script:Curl3) {
        Say "QUIC-строк: $($quic.Count) — пропускаются: штатный curl Windows не умеет HTTP/3." "DarkYellow"
        Say "  (Чтобы проверять и их, положите curl с HTTP/3 рядом под именем curl3.exe.)" "DarkGray"
    }
    if ($Mode -eq "best") {
        $min = [math]::Round(($rows | Where-Object { -not $_.Quic -or $script:Curl3 } | ForEach-Object { [int]$script:Pools[$_.Pool] } | Measure-Object -Sum).Sum * 12 / 60)
        Say "Ориентировочно: до $min мин. Прервать можно в любой момент (Ctrl+C) — текущая строка вернётся как была." "DarkGray"
    } else {
        Say "Прервать можно в любой момент (Ctrl+C) — текущая строка вернётся как была." "DarkGray"
    }
    if ((Ask "Начать? [Д/н]:").ToLower() -in @("н", "n", "нет", "no")) { return }
    Say "Обозначения: + прошло, x не прошло.`n" "DarkGray"

    $log = Join-Path $RunDir "5-strategies.tsv"
    if (-not (Test-Path $log)) { Write-Lines $log @("время`tрежим`tпул`tхост`tитог`tстратегия`tуспех`tср_время`tпримечание") }
    $matrix = Join-Path $RunDir "5-matrix.tsv"
    if ($Mode -eq "best" -and -not (Test-Path $matrix)) { Write-Lines $matrix @("пул`tхост`tстратегия`tуспех`tпопыток`tср_время") }

    $winners = @{}; $sum = @(); $idx = 0
    foreach ($row in $rows) {
        $idx++
        Say ("[{0}/{1}] {2} {3}" -f $idx, $rows.Count, $row.Pool, $row.HostKey) "Cyan"
        $note = ""
        if (-not $script:Pools.ContainsKey($row.Pool)) { $note = "нет такого пула" }
        elseif ($row.Quic -and -not $script:Curl3) { $note = "QUIC без curl3.exe" }
        if ($note) {
            Say "    пропуск: $note" "DarkYellow"
            Add-Line $log "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`t$Mode`t$($row.Pool)`t$($row.HostKey)`tпропуск`t`t`t`t$note"
            $sum += [pscustomobject]@{ Row = $row; Status = "пропуск"; Note = $note }; continue
        }
        Say "    проверяю: $($row.Url)" "DarkGray"

        $orig = $null
        try { $orig = Get-State | Where-Object { $_.key -eq $row.Pool -and $_.host -eq $row.HostKey } | Select-Object -First 1 } catch {}
        $cur = if ($orig) { [int]$orig.strategy } else { 1 }
        $size = [int]$script:Pools[$row.Pool]
        $found = $null; $best = $null; $finished = $false
        try {
            if ($Mode -eq "best") {
                $all = @()
                for ($n = 1; $n -le $size; $n++) {
                    Set-Row $row $n "frozen"; Start-Sleep -Seconds ([int]$Cfg.Settle)
                    $lbl = if ($n -eq $cur) { "текущая" } else { "страт. " }
                    $r = Test-Series $row $n ([int]$Cfg.LongTries) ([int]$Cfg.LongMaxFail) $lbl
                    $all += $r
                    Add-Line $matrix "$($row.Pool)`t$($row.HostKey)`t$n`t$($r.Ok)`t$($r.Done)`t$($r.Avg.ToString('0.000', $inv))"
                }
                $clean = @($all | Where-Object { $_.Ok -gt 0 -and $_.Ok -eq $_.Done } | ForEach-Object { $_.Strategy })
                if ($clean.Count) { Say ("    без единой неудачи: " + ($clean -join ", ")) "DarkGreen" }
                $fin = @($all | Where-Object { $_.Ok -gt 0 } |
                         Sort-Object @{e = { $_.Rate }; Descending = $true }, @{e = { $_.Ok }; Descending = $true }, @{e = { $_.Avg }; Descending = $false } |
                         Select-Object -First ([int]$Cfg.Finalists))
                if ($fin.Count) {
                    Say ("    финал: " + (($fin | ForEach-Object { $_.Strategy }) -join ", ") + " — по $([int]$Cfg.FinalTries) попыток")
                    $fr = @()
                    foreach ($f in $fin) {
                        Set-Row $row $f.Strategy "frozen"; Start-Sleep -Seconds ([int]$Cfg.Settle)
                        $fr += Test-Series $row $f.Strategy ([int]$Cfg.FinalTries) ([int]$Cfg.FinalTries + 1) "финал  "
                    }
                    $best = $fr | Sort-Object @{e = { $_.Rate }; Descending = $true }, @{e = { $_.Avg }; Descending = $false } | Select-Object -First 1
                    if ($best.Rate -ge [double]$Cfg.MinRate) { $found = $best }
                }
            } else {
                $order = New-Object System.Collections.Generic.List[int]
                $order.Add($cur)
                if ($winners.ContainsKey($row.Pool)) {
                    foreach ($w in ($winners[$row.Pool].GetEnumerator() | Sort-Object Value -Descending)) { if (-not $order.Contains([int]$w.Key)) { $order.Add([int]$w.Key) } }
                }
                for ($n = 1; $n -le $size; $n++) { if (-not $order.Contains($n)) { $order.Add($n) } }
                foreach ($n in $order) {
                    Set-Row $row $n "frozen"; Start-Sleep -Seconds ([int]$Cfg.Settle)
                    $lbl = if ($n -eq $cur) { "текущая" } else { "страт. " }
                    $r1 = Test-Series $row $n ([int]$Cfg.ShortTries) 1 $lbl
                    if (-not $best -or $r1.Ok -gt $best.Ok) { $best = $r1 }
                    if ($r1.Ok -lt [int]$Cfg.ShortTries) { continue }
                    $r2 = Test-Series $row $n ([int]$Cfg.ShortConfirm) ([int]$Cfg.ShortConfirmMaxFail + 1) "контр. "
                    if ($r2.Done -eq [int]$Cfg.ShortConfirm -and ($r2.Done - $r2.Ok) -le [int]$Cfg.ShortConfirmMaxFail) { $found = $r2; break }
                }
            }
            if ($found) {
                Set-Row $row $found.Strategy "frozen"
                $finished = $true
                if (-not $winners.ContainsKey($row.Pool)) { $winners[$row.Pool] = @{} }
                $winners[$row.Pool][$found.Strategy] = 1 + [int]$winners[$row.Pool][$found.Strategy]
                $st = if ($found.Strategy -eq $cur) { "оставлена" } else { "заморожена" }
                $avg = "{0:N2}" -f $found.Avg
                Say ("    => {0}: стратегия {1} ({2}/{3}, {4} с)" -f $st, $found.Strategy, $found.Ok, $found.Done, $avg) "Green"
                Add-Line $log "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`t$Mode`t$($row.Pool)`t$($row.HostKey)`t$st`t$($found.Strategy)`t$($found.Ok)/$($found.Done)`t$avg`t$($row.Url)"
                $sum += [pscustomobject]@{ Row = $row; Status = $st; Note = "стратегия $($found.Strategy)" }
            }
        } finally {
            if (-not $finished) {
                # ничего не нашли или прервали — вернуть строку как была
                try {
                    if ($orig) { Set-Row $row ([int]$orig.strategy) ([string]$orig.mode) }
                    else { Invoke-Panel "POST" "/state/delete" @{ key = $row.Pool; host = $row.HostKey } | Out-Null }
                } catch {}
            }
        }
        if (-not $finished) {
            $n2 = if ($best -and $best.Ok -gt 0) { "лучшая $($best.Strategy): $($best.Ok)/$($best.Done)" } else { "ни одна стратегия не прошла" }
            Say "    => стабильной стратегии нет, строка возвращена как была. $n2" "Red"
            Add-Line $log "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`t$Mode`t$($row.Pool)`t$($row.HostKey)`tне найдена`t`t`t`t$n2"
            $sum += [pscustomobject]@{ Row = $row; Status = "не найдена"; Note = $n2; Best = $(if ($best -and $best.Ok -gt 0) { $best } else { $null }) }
        }
    }

    Head "Итог подбора"
    foreach ($g in ($sum | Group-Object Status)) { Say ("  {0}: {1}" -f $g.Name, $g.Count) }
    $bad = @($sum | Where-Object { $_.Status -eq "не найдена" })
    if ($bad.Count) {
        Say "`nБез стабильной стратегии:" "Red"
        foreach ($b in $bad) { Say ("  {0,-8} {1,-28} {2}" -f $b.Row.Pool, $b.Row.Domain, $b.Note) "Red" }
    }
    # нестабильные: предложить всё же заморозить лучшую из найденных
    $weak = @($bad | Where-Object { $_.Best })
    if ($weak.Count) {
        Say "`nДля $($weak.Count) из них что-то проходило, но нестабильно." "DarkYellow"
        Say "Можно всё равно заморозить лучшую найденную — это лучше, чем ничего, а при перепроверке её заменит стабильная." "DarkGray"
        foreach ($w in $weak) { Say ("    {0,-8} {1,-28} стратегия {2}: {3}/{4}" -f $w.Row.Pool, $w.Row.Domain, $w.Best.Strategy, $w.Best.Ok, $w.Best.Done) "DarkYellow" }
        if ((Ask "Заморозить их лучшие стратегии? [д/Н]:").ToLower() -in @("д", "да", "y", "yes")) {
            foreach ($w in $weak) {
                try { Set-Row $w.Row $w.Best.Strategy "frozen"; Say "    заморожена $($w.Row.Pool) $($w.Row.Domain): стратегия $($w.Best.Strategy)" "Green"; $w.Note += " (заморожена нестабильная)" }
                catch { Say "    $($w.Row.Domain): $_" "Red" }
            }
        }
    }

    # список для перепроверки: убрать то, что нашлось, добавить то, что не нашлось
    $keep = @{}
    foreach ($r in (Read-Recheck)) { $keep["$($r.Pool)`t$($r.HostKey)"] = $r }
    foreach ($x in $sum) {
        $k = "$($x.Row.Pool)`t$($x.Row.HostKey)"
        if ($x.Status -in @("заморожена", "оставлена")) { $keep.Remove($k) }
        elseif ($x.Status -eq "не найдена") { $x.Row | Add-Member -NotePropertyName Note -NotePropertyValue $x.Note -Force; $keep[$k] = $x.Row }
    }
    Save-Recheck @($keep.Values)
    if ($keep.Count) {
        Copy-Item -LiteralPath $RecheckFile -Destination (Join-Path $RunDir "6-not-found.tsv") -Force
        Say "`nНе найденные ($($keep.Count)) сохранены для перепроверки: пункт [5] или z2k-recheck.bat" "Cyan"
    } else {
        Say "`nСписок для перепроверки пуст." "Green"
    }
    Say "Журнал: 5-strategies.tsv$(if ($Mode -eq 'best') { ', таблица по всем стратегиям: 5-matrix.tsv' })"
}

function Start-Recheck {
    $rows = @(Read-Recheck)
    if (-not $rows.Count) { Say "`nСписок для перепроверки пуст — перепроверять нечего." "Green"; return }
    Head "Перепроверка не найденных ($($rows.Count))"
    foreach ($r in $rows) { Say ("    {0,-8} {1,-28} {2}" -f $r.Pool, $r.Domain, $r.Note) }
    Say ""
    Say "  [1] короткий подбор   [2] длинный подбор (все стратегии)   [Enter] отмена" "White"
    $m = Ask "Выбор:"
    if ($m -eq "1") { Find-Strategies $rows "first" "Перепроверка" }
    elseif ($m -eq "2") { Find-Strategies $rows "best" "Перепроверка" }
}

# ============================================================================
#  ГЛАВНОЕ
# ============================================================================
Say "z2k-tool — проверка доменов автоподбора и подбор стратегий" "Cyan"
Connect-Panel

$script:Curl3 = ""
$c3 = Join-Path $BaseDir "curl3.exe"
if ((Test-Path $c3) -and ((& $c3 -V 2>$null) -join " ") -match "HTTP3") { $script:Curl3 = $c3; Say "Найден curl3.exe с HTTP/3 — QUIC-строки тоже будут проверяться." "DarkGray" }

$RunDir = Join-Path $BaseDir ("z2k-" + (Get-Date -Format "yyyyMMdd-HHmm"))
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
Say "Папка с результатами: $RunDir" "DarkGray"

if ("$env:Z2K_ARGS" -match "recheck") {
    # запуск из z2k-recheck.bat: только перепроверка сохранённого списка
    try { Start-Recheck } catch { Say "Ошибка: $_" "Red" }
    Say "Результаты: $RunDir" "DarkGray"
    return
}

$state = Export-State
if (-not $state.Count) { Say "Автоподбор пуст — проверять нечего."; exit 0 }
$res = Test-Domains $state
if ($null -eq $res) { exit 1 }

while ($true) {
    $nOpen = @($res.Values | Where-Object { $_.Kind -eq "open" }).Count
    $nBlk  = @($res.Values | Where-Object { $_.Kind -in @("blocked", "slow") }).Count
    Head "ШАГ 4. Что делаем дальше?"
    Say "  [1] Не блокируемые ($nOpen) — добавить в «Исключения»" "White"
    Say "  [2] Блокируемые ($nBlk) — КОРОТКИЙ подбор (первая подошедшая стратегия)" "White"
    Say "  [3] Блокируемые ($nBlk) — ДЛИННЫЙ подбор (все стратегии, лучшая)" "White"
    Say "  [4] Повторить выгрузку и проверку" "White"
    $nRe = @(Read-Recheck).Count
    Say "  [5] Перепроверить не найденные ($nRe)" "White"
    Say "  [0] Выход" "White"
    $a = Ask "Выбор:"
    try {
        switch ($a) {
            "1" { Add-Exclusions $res }
            "2" { $state = Get-State; Find-Strategies (Get-BlockedRows $state $res) "first" }
            "3" { $state = Get-State; Find-Strategies (Get-BlockedRows $state $res) "best" }
            "4" { $state = Export-State; $r2 = Test-Domains $state; if ($r2) { $res = $r2 } }
            "5" { Start-Recheck }
            "0" { Say "Результаты: $RunDir" "DarkGray"; return }
            default { Say "Нет такого пункта." "DarkYellow" }
        }
    } catch {
        Say "Ошибка: $_" "Red"
    }
}
