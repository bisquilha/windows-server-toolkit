<#
.SYNOPSIS
    Descobre QUAL componente trava o login/logoff e deixa sessoes zumbis no SERVIDOR01.
    SOMENTE LEITURA. Rodar ANTES de reiniciar (o reinicio apaga a evidencia das sessoes presas).
#>
$ErrorActionPreference = 'SilentlyContinue'
function W($t) { Write-Output $t }
function Linha($e) { $m = ((($e.Message -split "`n") | Select-Object -First 1) -replace '\s+', ' ').Trim(); if ($m.Length -gt 170) { $m = $m.Substring(0, 170) }; '{0:dd/MM HH:mm:ss.fff} {1,-5} {2}' -f $e.TimeCreated, $e.Id, $m }

$janelas = @(
    @('2026-10-16 15:13:30', '2026-10-16 15:16:30', 'sessao 14 (zumbi)'),
    @('2026-10-16 16:31:00', '2026-10-16 16:35:00', 'sessao 16 (zumbi)'),
    @((Get-Date).AddHours(-4).ToString('yyyy-MM-dd HH:mm:ss'), (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), 'ultimas 4 h (logins de hoje)')
)

W '=== A) WINLOGON: cada componente que o login chama (811 = comecou, 812 = terminou, 6005/6006 = demorou) ==='
W '    O componente que COMECA e nao TERMINA e quem prende a sessao.'
foreach ($j in $janelas) {
    W ''; W "--- $($j[2]): $($j[0]) a $($j[1]) ---"
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Winlogon/Operational'; StartTime = [datetime]$j[0]; EndTime = [datetime]$j[1] } | Sort-Object TimeCreated)
    if (-not $ev.Count) { W '  (sem eventos de Winlogon nesta janela)'; continue }
    $ev | Select-Object -Last 60 | ForEach-Object { W ('  ' + (Linha $_)) }
    $abertos = @{}
    foreach ($e in $ev) {
        if ($e.Message -match 'subscriber <(.+?)> (began|finished) handling the notification event \((\d+)\)') {
            $k = "$($matches[1]) / evento $($matches[3])"
            if ($matches[2] -eq 'began') { $abertos[$k] = $e.TimeCreated } else { $abertos.Remove($k) }
        }
    }
    if ($abertos.Count) { W '  >>> COMECARAM E NAO TERMINARAM:'; $abertos.GetEnumerator() | Sort-Object Value | ForEach-Object { W ("      {0:HH:mm:ss}  {1}" -f $_.Value, $_.Key) } }
    $lentos = $ev | Where-Object { $_.Id -in 6005, 6006 }
    if ($lentos) { W '  >>> DEMORARAM (6005/6006):'; $lentos | ForEach-Object { W ('      ' + (Linha $_)) } }
}

W ''; W '=== B) SESSOES ZUMBIS AGORA ==='
$z = Get-CimInstance Win32_Process | Group-Object SessionId | Where-Object { $_.Name -ne '0' -and -not ($_.Group.Name | Where-Object { $_ -ne 'csrss.exe' }) }
if (-not $z) { W '  nenhuma' }
foreach ($s in $z) {
    $p = $s.Group[0]
    W "  Sessao $($s.Name): csrss PID $($p.ProcessId), criado $($p.CreationDate), handles $($p.HandleCount), threads $($p.ThreadCount)"
}

W ''; W '=== C) PROGRAMAS QUE ACOMPANHAM AS SESSOES (agentes remotos e afins) ==='
Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'AnyDesk|MeshAgent|tacticalrmm|Iperius|TeamViewer|rustdesk|ScreenConnect' } |
    Sort-Object Name, SessionId | ForEach-Object { W ("  {0,-22} PID {1,-6} sessao {2,-3} desde {3}" -f $_.Name, $_.ProcessId, $_.SessionId, $_.CreationDate) }

W ''; W '=== D) QUEDAS DO MESH AGENT x HORARIO DAS ZUMBIS (ultimos 5 dias) ==='
Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 7031, 7034; StartTime = (Get-Date).AddDays(-5) } |
    Where-Object { $_.Message -match 'Mesh|AnyDesk|Iperius|tactical' } | Sort-Object TimeCreated | Select-Object -Last 25 | ForEach-Object { W ('  ' + (Linha $_)) }

W ''; W '=== E) FALHAS DE PROGRAMAS E DO WINLOGON NAS JANELAS DAS ZUMBIS ==='
foreach ($j in $janelas[0..1]) {
    $a = ([datetime]$j[0]).AddMinutes(-5); $b = ([datetime]$j[1]).AddMinutes(10)
    $ev = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000, 1002, 4005, 4006, 6001, 6004; StartTime = $a; EndTime = $b }
    W "  --- $($j[2]) ---"; if ($ev) { $ev | Sort-Object TimeCreated | ForEach-Object { W ('    ' + (Linha $_)) } } else { W '    (nenhuma)' }
}

W ''; W '=== F) LOCAL SESSION MANAGER / REMOTE CONNECTION (logs Admin, 5 dias) ==='
foreach ($l in 'Microsoft-Windows-TerminalServices-LocalSessionManager/Admin', 'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Admin') {
    Get-WinEvent -FilterHashtable @{ LogName = $l; StartTime = (Get-Date).AddDays(-5) } | Sort-Object TimeCreated | Select-Object -Last 15 | ForEach-Object { W ('  ' + (Linha $_)) }
}
W ''; W 'Fim.'
