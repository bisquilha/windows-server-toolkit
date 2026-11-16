<#
.SYNOPSIS
    Descobre QUAL processo de servico do Windows esta preso e impede a montagem das sessoes RDP (SERVIDOR01).
    SOMENTE LEITURA: usa "sc interrogate" (so pergunta ao servico se esta vivo; nao para, nao inicia, nao altera).
    Nao toca em servicos da TOTVS. Rodar ANTES de reiniciar.
#>
$ErrorActionPreference = 'SilentlyContinue'
function W($t) { Write-Output $t }
$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
$dir = "C:\Temp\interrogate_$ts"; New-Item -ItemType Directory -Force $dir | Out-Null

$svc = @(Get-CimInstance Win32_Service)
$chave = 'ProfSvc', 'SessionEnv', 'TermService', 'UmRdpService', 'LSM', 'gpsvc', 'UserManager', 'Winmgmt', 'Spooler', 'Appinfo', 'iphlpsvc', 'NlaSvc', 'wuauserv', 'CryptSvc', 'Schedule'
$pids = @($svc | Where-Object { $_.Name -in $chave -and $_.ProcessId -gt 0 } | Select-Object -ExpandProperty ProcessId -Unique)

W '=== 1) PROCESSOS QUE HOSPEDAM OS SERVICOS DE SESSAO ==='
foreach ($p in $pids) {
    $pr = Get-Process -Id $p
    $nomes = ($svc | Where-Object ProcessId -eq $p | Sort-Object Name | Select-Object -ExpandProperty Name) -join ', '
    W ("  PID {0,-6} handles {1,-6} threads {2,-5} RAM {3,6} MB  CPU {4,8} s  desde {5}" -f $p, $pr.HandleCount, $pr.Threads.Count, [math]::Round($pr.WorkingSet64 / 1MB), [math]::Round($pr.CPU), $pr.StartTime)
    W "     servicos: $nomes"
}

W ''; W '=== 2) TESTE: cada servico responde? (sc interrogate, espera ate 40 s) ==='
$alvo = @($svc | Where-Object { $_.ProcessId -in $pids -and $_.State -eq 'Running' } | Select-Object -ExpandProperty Name | Sort-Object -Unique)
foreach ($s in $alvo) { Start-Process sc.exe -ArgumentList "interrogate `"$s`"" -RedirectStandardOutput "$dir\$s.txt" -NoNewWindow }
Start-Sleep -Seconds 40
$res = foreach ($s in $alvo) {
    $o = Get-Content "$dir\$s.txt" -Raw
    $st = if ($o -match 'FAILED 1053') { 'NAO RESPONDE (1053)' } elseif ($o -match 'FAILED 1061') { 'ocupado (1061)' } elseif ($o -match 'FAILED (\d+)') { "falha $($matches[1])" } elseif ($o -match 'STATE|ESTADO') { 'ok' } else { 'SEM RESPOSTA EM 40 s' }
    [pscustomobject]@{ Servico = $s; PID = ($svc | Where-Object Name -eq $s).ProcessId; Resposta = $st }
}
$res | Sort-Object @{ e = { if ($_.Resposta -eq 'ok') { 1 } else { 0 } } }, PID, Servico | Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { W $_.TrimEnd() }
$presos = @($res | Where-Object Resposta -ne 'ok')
if ($presos.Count) { W "  >>> SERVICOS QUE NAO RESPONDEM: $(($presos | ForEach-Object { "$($_.Servico)(PID $($_.PID))" }) -join ', ')" } else { W '  >>> todos responderam' }

W ''; W '=== 3) SERVICOS QUE MAIS DERAM TIMEOUT (7011) - 7 dias ==='
Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 7011; StartTime = (Get-Date).AddDays(-7) } |
    ForEach-Object { if ($_.Message -match 'from the (.+?) service') { $matches[1] } } | Group-Object | Sort-Object Count -Descending | Select-Object -First 15 |
    ForEach-Object { W ("  {0,4}x  {1}" -f $_.Count, $_.Name) }

W ''; W '=== 4) WMI: quem consulta (WmiPrvSE e erros por processo cliente, 6 h) ==='
Get-Process WmiPrvSE | ForEach-Object { W ("  WmiPrvSE PID {0,-6} CPU {1,7} s  RAM {2,5} MB  handles {3}" -f $_.Id, [math]::Round($_.CPU), [math]::Round($_.WS / 1MB), $_.HandleCount) }
$wmi = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-WMI-Activity/Operational'; StartTime = (Get-Date).AddHours(-6) }
$porCliente = $wmi | ForEach-Object { if ($_.Message -match 'ClientProcessId\s*=\s*(\d+)') { $cp = [int]$matches[1]; $n = (Get-Process -Id $cp).ProcessName; if (-not $n) { $n = "PID $cp (ja encerrado)" }; $n } } | Group-Object | Sort-Object Count -Descending | Select-Object -First 8
if ($porCliente) { $porCliente | ForEach-Object { W ("  {0,5} erros WMI de {1}" -f $_.Count, $_.Name) } } else { W '  (sem erros WMI)' }

W ''; W '=== 5) WINDOWS UPDATE: quando rodou (7 dias) ==='
Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 7036; StartTime = (Get-Date).AddDays(-7) } |
    Where-Object { $_.Message -match '(Windows Update|Windows Modules Installer) service entered the (running|stopped) state' } |
    Sort-Object TimeCreated | Select-Object -Last 30 | ForEach-Object { W ("  {0:ddd dd/MM HH:mm:ss}  {1}" -f $_.TimeCreated, (($_.Message -split "`n")[0]).Trim()) }

W ''; W "Fim. Respostas brutas em $dir"
