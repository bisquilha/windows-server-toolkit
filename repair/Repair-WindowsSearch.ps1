<#
.SYNOPSIS
    Diagnóstico e correção do loop do Windows Search (7000/7009/DCOM 10005 erro 1053).
.PARAMETER Modo
    Diagnostico  (padrão) - só lê, não altera nada
    Reconstruir  - para o serviço, renomeia o índice (Windows.edb) e sobe de novo do zero
    Desativar    - para e desativa o serviço (servidor de aplicação não precisa de indexação)
    Reverter     - volta o serviço para Automático (Atraso) e inicia
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Downloads\Repair-WindowsSearch.ps1"
    powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Downloads\Repair-WindowsSearch.ps1" -Modo Reconstruir
#>
param(
    [ValidateSet('Diagnostico','Reconstruir','Desativar','Reverter')]
    [string]$Modo = 'Diagnostico'
)

$ErrorActionPreference = 'Continue'
$dataDir = 'C:\ProgramData\Microsoft\Search\Data\Applications\Windows'
$regKey  = 'HKLM:\SOFTWARE\Microsoft\Windows Search'

function Titulo($t) { Write-Host "`n==== $t ====" -ForegroundColor Cyan }

function Diagnostico {
    Titulo "SERVIÇO"
    Get-CimInstance Win32_Service -Filter "Name='WSearch'" |
        Select-Object Name, State, StartMode, DelayedAutoStart, StartName, ProcessId, PathName | Format-List | Out-String | Write-Host
    Get-Process SearchIndexer, SearchProtocolHost, SearchFilterHost -ErrorAction SilentlyContinue |
        Select-Object Name, Id, @{n='RAM_MB';e={[math]::Round($_.WorkingSet64/1MB)}}, Handles | Format-Table -AutoSize | Out-String | Write-Host

    Titulo "ÍNDICE (Windows.edb)"
    $s = Get-ItemProperty $regKey -ErrorAction SilentlyContinue
    Write-Host ("  DataDirectory registrado: {0}" -f $s.DataDirectory)
    Write-Host ("  SetupCompletedSuccessfully: {0}" -f $s.SetupCompletedSuccessfully)
    if (Test-Path $dataDir) {
        Get-ChildItem $dataDir -Recurse -File -ErrorAction SilentlyContinue | Sort-Object Length -Descending | Select-Object -First 5 FullName,
            @{n='MB';e={[math]::Round($_.Length/1MB)}}, LastWriteTime | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
    } else { Write-Host "  Pasta do índice não existe: $dataDir" -ForegroundColor Yellow }
    $c = Get-Volume -DriveLetter C
    Write-Host ("  C: livre = {0:N1} GB" -f ($c.SizeRemaining/1GB))

    Titulo "TAXA DO LOOP (últimos 10 min)"
    $n = (Get-WinEvent -FilterHashtable @{LogName='System'; Id=7009; StartTime=(Get-Date).AddMinutes(-10)} -ErrorAction SilentlyContinue | Measure-Object).Count
    Write-Host ("  Eventos 7009 nos últimos 10 min: {0}  (~{1:N1}/min)" -f $n, ($n/10)) -ForegroundColor Yellow
    $first = Get-WinEvent -FilterHashtable @{LogName='System'; Id=7009} -Oldest -MaxEvents 1 -ErrorAction SilentlyContinue
    Write-Host ("  Primeiro 7009 ainda no log: {0}" -f $first.TimeCreated)

    Titulo "LOG DO PRÓPRIO SEARCH / ESENT (últimos 10)"
    Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='Microsoft-Windows-Search','ESENT'; StartTime=(Get-Date).AddDays(-3)} -MaxEvents 10 -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, ProviderName, Id, @{n='Msg';e={ ($_.Message -split "`r?`n" | Where-Object {$_})[0..1] -join ' ' }} |
        Format-Table -AutoSize -Wrap | Out-String -Width 250 | Write-Host

    Titulo "SESSÕES RDP (cada uma tem um SearchUI chamando o serviço)"
    query user 2>$null | Write-Host
    Write-Host ("  SearchUI em execução: {0}" -f @(Get-Process SearchUI -ErrorAction SilentlyContinue).Count)
}

function Para-Search {
    Write-Host "Parando WSearch..."
    Set-Service WSearch -StartupType Disabled            # impede o DCOM de religar no meio do processo
    Stop-Service WSearch -Force -ErrorAction SilentlyContinue
    Start-Sleep 3
    Get-Process SearchIndexer, SearchProtocolHost, SearchFilterHost -ErrorAction SilentlyContinue | Stop-Process -Force
    # Se o serviço ficou preso em "Stopping"/"Starting", mata pelo PID
    $svc = Get-CimInstance Win32_Service -Filter "Name='WSearch'"
    if ($svc.ProcessId -gt 0) { Stop-Process -Id $svc.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep 2
    Write-Host ("  Estado: {0}" -f (Get-Service WSearch).Status)
}

switch ($Modo) {
    'Diagnostico' { Diagnostico }

    'Reconstruir' {
        Diagnostico
        Para-Search
        if (Test-Path $dataDir) {
            $bak = "$dataDir.old_$(Get-Date -Format 'yyyyMMdd_HHmm')"
            Write-Host "Renomeando índice para $bak"
            Rename-Item $dataDir $bak -ErrorAction Stop
        }
        Set-ItemProperty $regKey -Name SetupCompletedSuccessfully -Value 0 -Type DWord   # força recriar o índice
        sc.exe config WSearch start= delayed-auto | Out-Null
        Start-Service WSearch
        Start-Sleep 20
        Titulo "RESULTADO"
        Get-Service WSearch | Select-Object Name, Status, StartType | Format-Table -AutoSize | Out-String | Write-Host
        Write-Host "Se ficou Running, apague a pasta .old_* depois de alguns dias. Se não subiu, rode -Modo Desativar." -ForegroundColor Green
    }

    'Desativar' {
        Para-Search
        Titulo "RESULTADO"
        Get-Service WSearch | Select-Object Name, Status, StartType | Format-Table -AutoSize | Out-String | Write-Host
        Write-Host "Desativado. Para voltar: -Modo Reverter" -ForegroundColor Green
    }

    'Reverter' {
        sc.exe config WSearch start= delayed-auto | Out-Null
        Start-Service WSearch
        Get-Service WSearch | Select-Object Name, Status, StartType | Format-Table -AutoSize | Out-String | Write-Host
    }
}

if ($Modo -ne 'Diagnostico') {
    Write-Host "`nAguarde 5 min e rode de novo em modo Diagnostico para ver se a taxa de 7009 zerou." -ForegroundColor Yellow
}
