<#
.SYNOPSIS
    Ajustes de desempenho do Windows no SERVIDOR01 - tira do disco tarefas que nao precisam rodar num servidor de producao.
    NAO mexe em Protheus/TOTVS. NAO reinicia. Tudo com backup e com -Etapa Desfazer.
.PARAMETER Etapa
    Verificar - so le: mostra o que roda hoje e quando (telemetria, desfragmentacao, Windows Update, processos pesados)
    Aplicar   - desliga telemetria (CompatTelRunner/DeviceCensus) e a desfragmentacao automatica do array
    Desfazer  - volta tudo ao estado salvo pelo Aplicar
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Downloads\Optimize-ServerPerformance.ps1" -Etapa Verificar
#>
param([Parameter(Mandatory = $true)][ValidateSet('Verificar', 'Aplicar', 'Desfazer')][string]$Etapa)

$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force C:\Temp | Out-Null
$bkDir = 'C:\Temp\Ajustes_Desempenho_backup'
Start-Transcript "C:\Temp\Ajustes_${Etapa}_$(Get-Date -Format 'yyyyMMdd_HHmm').txt" -Force | Out-Null
function Titulo($t) { Write-Host "`n==== $t ====" -ForegroundColor Cyan }
function Tab($o) { if ($o) { $o | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host } else { Write-Host '  (nada)' } }

# tarefas que leem o disco inteiro periodicamente e nao tem funcao num servidor de producao
$tarefas = @(
    @{ P = '\Microsoft\Windows\Application Experience\'; N = 'Microsoft Compatibility Appraiser' },
    @{ P = '\Microsoft\Windows\Application Experience\'; N = 'ProgramDataUpdater' },
    @{ P = '\Microsoft\Windows\Application Experience\'; N = 'StartupAppTask' },
    @{ P = '\Microsoft\Windows\Customer Experience Improvement Program\'; N = 'Consolidator' },
    @{ P = '\Microsoft\Windows\Customer Experience Improvement Program\'; N = 'KernelCeipTask' },
    @{ P = '\Microsoft\Windows\Customer Experience Improvement Program\'; N = 'UsbCeip' },
    @{ P = '\Microsoft\Windows\Device Information\'; N = 'Device' },
    @{ P = '\Microsoft\Windows\Defrag\'; N = 'ScheduledDefrag' }
)
$servicos = 'DiagTrack', 'dmwappushservice'

switch ($Etapa) {

'Verificar' {
    Titulo 'Tarefas que leem o disco (telemetria e desfragmentacao)'
    Tab $(foreach ($t in $tarefas) { $x = Get-ScheduledTask -TaskPath $t.P -TaskName $t.N -ErrorAction SilentlyContinue; if ($x) { $i = $x | Get-ScheduledTaskInfo; [pscustomobject]@{ Tarefa = $t.N; Estado = $x.State; Ultima = $i.LastRunTime; Proxima = $i.NextRunTime } } })
    Titulo 'Servicos de telemetria'
    Tab (Get-Service $servicos -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType)
    Titulo 'Desfragmentacoes executadas (ultimos 60 dias)'
    Tab (Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Microsoft-Windows-Defrag'; StartTime = (Get-Date).AddDays(-60) } -ErrorAction SilentlyContinue | Select-Object -First 10 TimeCreated, Id, @{ n = 'Msg'; e = { (($_.Message -split "`n")[0]).Trim() } })
    Titulo 'Quando o Windows Update / instalador de modulos rodaram (ultimos 14 dias)'
    $wu = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 7036; StartTime = (Get-Date).AddDays(-14) } -ErrorAction SilentlyContinue | Where-Object { $_.Message -match '(Windows Update|Windows Modules Installer) service entered the running state' }
    Tab ($wu | Select-Object -First 30 @{ n = 'Hora'; e = { $_.TimeCreated.ToString('ddd dd/MM HH:mm') } }, @{ n = 'Servico'; e = { if ($_.Message -match 'Modules') { 'Instalador de modulos' } else { 'Windows Update' } } })
    Titulo 'Politica local do Windows Update'
    $au = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ErrorAction SilentlyContinue
    Write-Host "  AUOptions=$($au.AUOptions)  NoAutoUpdate=$($au.NoAutoUpdate)  ScheduledInstallDay=$($au.ScheduledInstallDay)  ScheduledInstallTime=$($au.ScheduledInstallTime)"
    Titulo 'Programas de terceiros rodando nas sessoes (o que e o Iperius?)'
    Tab (Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'Iperius|jucheck|jusched|CompatTelRunner|DeviceCensus' } | Select-Object Name, ProcessId, SessionId, ExecutablePath)
    Tab (Get-CimInstance Win32_Service | Where-Object { $_.Name -match 'Iperius' -or $_.PathName -match 'Iperius' } | Select-Object Name, DisplayName, State, StartMode, PathName)
}

'Aplicar' {
    New-Item -ItemType Directory -Force $bkDir | Out-Null
    Titulo 'Desligando tarefas que leem o disco (backup em C:\Temp\Ajustes_Desempenho_backup)'
    foreach ($t in $tarefas) {
        $x = Get-ScheduledTask -TaskPath $t.P -TaskName $t.N -ErrorAction SilentlyContinue
        if (-not $x) { Write-Host "  (nao existe) $($t.N)"; continue }
        "$($t.P)|$($t.N)|$($x.State)" | Add-Content "$bkDir\tarefas.txt"
        Disable-ScheduledTask -TaskPath $t.P -TaskName $t.N | Out-Null
        Write-Host "  OK desligada: $($t.N)" -ForegroundColor Green
    }
    Titulo 'Desligando servicos de telemetria'
    foreach ($s in $servicos) {
        $x = Get-CimInstance Win32_Service -Filter "Name='$s'"
        if (-not $x) { continue }
        "$s|$($x.StartMode)" | Add-Content "$bkDir\servicos.txt"
        Stop-Service $s -Force -ErrorAction SilentlyContinue
        Set-Service $s -StartupType Disabled
        Write-Host "  OK desligado: $s (era $($x.StartMode))" -ForegroundColor Green
    }
    Get-Process CompatTelRunner, DeviceCensus -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host "`n  Pronto. Nada foi reiniciado. Para voltar: -Etapa Desfazer" -ForegroundColor Cyan
}

'Desfazer' {
    Titulo 'Restaurando tarefas'
    if (Test-Path "$bkDir\tarefas.txt") {
        foreach ($l in Get-Content "$bkDir\tarefas.txt") { $p, $n, $e = $l.Split('|'); if ($e -ne 'Disabled') { Enable-ScheduledTask -TaskPath $p -TaskName $n | Out-Null; Write-Host "  OK religada: $n" -ForegroundColor Green } }
    }
    Titulo 'Restaurando servicos'
    if (Test-Path "$bkDir\servicos.txt") {
        foreach ($l in Get-Content "$bkDir\servicos.txt") { $n, $m = $l.Split('|'); $tipo = switch ($m) { 'Auto' { 'Automatic' } 'Manual' { 'Manual' } default { 'Disabled' } }; Set-Service $n -StartupType $tipo; if ($tipo -eq 'Automatic') { Start-Service $n -ErrorAction SilentlyContinue }; Write-Host "  OK $n -> $tipo" -ForegroundColor Green }
    }
}
}
Stop-Transcript | Out-Null
