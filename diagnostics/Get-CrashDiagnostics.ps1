<#
.SYNOPSIS
    Diagnóstico pós-travamento (hard reset) de servidor Windows.
.DESCRIPTION
    Coleta: boot/desligamentos inesperados, BSOD/dumps, erros de hardware (WHEA),
    disco/storage, esgotamento de recursos, serviços que caíram, apps que travaram,
    SQL Server, e a "última atividade" registrada antes do reset.
    Gera relatório em C:\Temp\Diag_<host>_<data>.txt
.EXAMPLE
    # PowerShell como Administrador:
    Set-ExecutionPolicy -Scope Process Bypass -Force
    .\Get-CrashDiagnostics.ps1 -Dias 3
#>
param(
    [int]$Dias = 3   # janela de análise em dias
)

$ErrorActionPreference = 'SilentlyContinue'
$inicio  = (Get-Date).AddDays(-$Dias)
$outDir  = 'C:\Temp'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$relatorio = Join-Path $outDir ("Diag_{0}_{1}.txt" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmm'))
Start-Transcript -Path $relatorio -Force | Out-Null

function Titulo($t) { Write-Host "`n==================== $t ====================" -ForegroundColor Cyan }

function Busca-Eventos {
    param([string]$Log, [int[]]$Ids, [string]$Provider, [int[]]$Level, [datetime]$Desde = $inicio, [datetime]$Ate = (Get-Date))
    $f = @{ LogName = $Log; StartTime = $Desde; EndTime = $Ate }
    if ($Ids)      { $f.Id = $Ids }
    if ($Provider) { $f.ProviderName = $Provider }
    if ($Level)    { $f.Level = $Level }
    Get-WinEvent -FilterHashtable $f -ErrorAction SilentlyContinue
}

function Mostra($eventos, [int]$max = 25) {
    if (-not $eventos) { Write-Host "  (nenhum)" -ForegroundColor DarkGray; return }
    Write-Host "  Total: $(@($eventos).Count)  | Por ID:" -ForegroundColor Yellow
    $eventos | Group-Object Id | Sort-Object Count -Descending |
        ForEach-Object { "    ID {0,-6} x{1,-4} {2}" -f $_.Name, $_.Count, $_.Group[0].ProviderName } | Write-Host
    $eventos | Select-Object -First $max TimeCreated, Id, ProviderName,
        @{n='Mensagem';e={ ($_.Message -split "`r?`n")[0] -replace '\s+',' ' | ForEach-Object { $_.Substring(0,[Math]::Min(160,$_.Length)) } }} |
        Format-Table -AutoSize -Wrap | Out-String -Width 250 | Write-Host
}

# ---------------------------------------------------------------- SISTEMA
Titulo "SISTEMA"
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
[pscustomobject]@{
    Host          = $env:COMPUTERNAME
    SO            = "$($os.Caption) build $($os.BuildNumber)"
    Fabricante    = $cs.Manufacturer
    Modelo        = $cs.Model            # QEMU / Standard PC = VM no Proxmox
    BIOS          = $bios.SMBIOSBIOSVersion
    UltimoBoot    = $os.LastBootUpTime
    Uptime        = ((Get-Date) - $os.LastBootUpTime).ToString('d\d\ hh\h\ mm\m')
    RAM_GB        = [math]::Round($cs.TotalPhysicalMemory/1GB,1)
    RAMLivre_GB   = [math]::Round($os.FreePhysicalMemory/1MB,1)
    CPUs          = $cs.NumberOfLogicalProcessors
} | Format-List | Out-String | Write-Host

# ---------------------------------------------------------------- HISTÓRICO DE BOOT / DESLIGAMENTO
Titulo "BOOTS E DESLIGAMENTOS (41=perda de energia/reset, 6008=desligamento inesperado, 1074=desligamento por usuário, 6005=boot)"
Mostra (Busca-Eventos -Log System -Ids 41,6008,1074,6005,6006,6009,1076)

# ---------------------------------------------------------------- BSOD / DUMPS
Titulo "TELA AZUL (BugCheck 1001) e DUMPS"
Mostra (Busca-Eventos -Log System -Ids 1001 -Provider 'Microsoft-Windows-WER-SystemErrorReporting')
$kp41 = Busca-Eventos -Log System -Ids 41 | Select-Object -First 3
foreach ($e in $kp41) {
    $x = [xml]$e.ToXml()
    $bc = ($x.Event.EventData.Data | Where-Object Name -eq 'BugcheckCode').'#text'
    Write-Host ("  Kernel-Power 41 em {0}: BugcheckCode={1} {2}" -f $e.TimeCreated, $bc,
        $(if ($bc -eq '0') {'-> SEM tela azul: travamento total / reset físico / energia'} else {'-> houve BSOD, ver dump'})) -ForegroundColor Yellow
}
Write-Host "`n  Arquivos de dump:"
Get-ChildItem C:\Windows\Minidump\*.dmp, C:\Windows\MEMORY.DMP |
    Select-Object FullName, LastWriteTime, @{n='MB';e={[math]::Round($_.Length/1MB,1)}} | Format-Table -AutoSize | Out-String | Write-Host
$cc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
Write-Host ("  CrashDumpEnabled={0} (0=desligado,1=completo,2=kernel,3=mini,7=automático)  AutoReboot={1}" -f $cc.CrashDumpEnabled, $cc.AutoReboot)

# ---------------------------------------------------------------- ÚLTIMOS SINAIS DE VIDA ANTES DO RESET
Titulo "ÚLTIMOS EVENTOS ANTES DO ÚLTIMO BOOT (o que aconteceu antes de travar)"
$boot = $os.LastBootUpTime
$antes = @()
foreach ($log in 'System','Application') {
    $antes += Busca-Eventos -Log $log -Desde $boot.AddHours(-6) -Ate $boot.AddSeconds(-5)
}
$antes = $antes | Sort-Object TimeCreated -Descending
if ($antes) {
    Write-Host ("  Último evento gravado antes do reset: {0}  (gap até o boot: {1:N0} min)" -f `
        $antes[0].TimeCreated, ($boot - $antes[0].TimeCreated).TotalMinutes) -ForegroundColor Yellow
    Write-Host "  -> Gap grande = máquina congelou e parou de logar bem antes do botão ser apertado.`n"
    Write-Host "  -- Últimos 40 eventos (todos os níveis):"
    $antes | Select-Object -First 40 TimeCreated, LogName, LevelDisplayName, Id, ProviderName,
        @{n='Mensagem';e={ ($_.Message -split "`r?`n")[0] | ForEach-Object { $_.Substring(0,[Math]::Min(120,$_.Length)) } }} |
        Format-Table -AutoSize -Wrap | Out-String -Width 250 | Write-Host
    Write-Host "  -- Só Critical/Error/Warning nas 6h antes:"
    Mostra ($antes | Where-Object Level -in 1,2,3) 40
}

# ---------------------------------------------------------------- HARDWARE
Titulo "HARDWARE - WHEA (erros de CPU/RAM/PCIe)"
Mostra (Busca-Eventos -Log System -Provider 'Microsoft-Windows-WHEA-Logger')

Titulo "DISCO / STORAGE (7,11,51,153=disco; 129=reset controladora; 55,98,140=NTFS; 157=disco removido)"
Mostra (Busca-Eventos -Log System -Ids 7,11,15,51,52,129,153,154,157,55,98,140,50,57)
Write-Host "  Saúde dos discos físicos:"
Get-PhysicalDisk | ForEach-Object {
    $r = $_ | Get-StorageReliabilityCounter
    [pscustomobject]@{ Disco=$_.FriendlyName; Tipo=$_.MediaType; Saude=$_.HealthStatus; Status=$_.OperationalStatus
        GB=[math]::Round($_.Size/1GB); Temp=$r.Temperature; ErrosLeitura=$r.ReadErrorsTotal; ErrosEscrita=$r.WriteErrorsTotal
        LatMaxLeitura_ms=$r.ReadLatencyMax; LatMaxEscrita_ms=$r.WriteLatencyMax; Desgaste=$r.Wear }
} | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
Write-Host "  Espaço em volumes:"
Get-Volume | Where-Object DriveLetter | Select-Object DriveLetter, FileSystemLabel, HealthStatus,
    @{n='TotalGB';e={[math]::Round($_.Size/1GB,1)}}, @{n='LivreGB';e={[math]::Round($_.SizeRemaining/1GB,1)}},
    @{n='Livre%';e={ if ($_.Size) {[math]::Round(100*$_.SizeRemaining/$_.Size,1)} }} | Format-Table -AutoSize | Out-String | Write-Host

# ---------------------------------------------------------------- RECURSOS
Titulo "ESGOTAMENTO DE RECURSOS (2004=memória virtual baixa) / pagefile"
Mostra (Busca-Eventos -Log System -Ids 2004,2019,2020,333)
Get-CimInstance Win32_PageFileUsage | Select-Object Name, AllocatedBaseSize, CurrentUsage, PeakUsage | Format-Table -AutoSize | Out-String | Write-Host
$c = (Get-Counter '\Memory\Pool Nonpaged Bytes','\Memory\Pool Paged Bytes','\Memory\Committed Bytes','\Memory\Commit Limit').CounterSamples
$c | Select-Object @{n='Contador';e={$_.Path -replace '^.*\\memory\\',''}}, @{n='MB';e={[math]::Round($_.CookedValue/1MB)}} | Format-Table -AutoSize | Out-String | Write-Host

Titulo "TOP 15 PROCESSOS (RAM / Handles) - procure vazamento"
Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 15 Name, Id,
    @{n='RAM_MB';e={[math]::Round($_.WorkingSet64/1MB)}}, @{n='Privada_MB';e={[math]::Round($_.PrivateMemorySize64/1MB)}},
    Handles, @{n='Threads';e={$_.Threads.Count}}, @{n='CPU_s';e={[math]::Round($_.CPU)}} | Format-Table -AutoSize | Out-String | Write-Host
Get-Process | Sort-Object Handles -Descending | Select-Object -First 5 Name, Id, Handles | Format-Table -AutoSize | Out-String | Write-Host

# ---------------------------------------------------------------- SERVIÇOS / APLICAÇÕES
Titulo "SERVIÇOS QUE CAÍRAM / TIMEOUT (7031,7034 caiu; 7011,7009 timeout; 7022-7024 falha start)"
Mostra (Busca-Eventos -Log System -Ids 7031,7034,7011,7009,7022,7023,7024,7000,7001)

Titulo "APLICAÇÕES QUE CRASHARAM/TRAVARAM (1000 crash, 1002 hang, 1026 .NET)"
Mostra (Busca-Eventos -Log Application -Ids 1000,1002,1026)

Titulo "SQL SERVER (17883 scheduler travado, 833 I/O >15s, 701 sem memória, 17890 memória paginada)"
Mostra (Busca-Eventos -Log Application -Ids 17883,17884,17888,833,701,17890,824,823,9002)

Titulo "VIRTUALIZAÇÃO / DRIVERS (se for VM Proxmox: virtio, balloon, guest agent)"
Mostra (Busca-Eventos -Log System -Provider 'vioscsi','viostor','netkvm','balloon','vioser')
Get-Service | Where-Object { $_.Name -match 'QEMU|qemu-ga|Balloon|vioser|spice' } |
    Select-Object Name, Status, StartType | Format-Table -AutoSize | Out-String | Write-Host

Titulo "REDE (falhas de NIC, 27=link caiu, 4199 conflito IP)"
Mostra (Busca-Eventos -Log System -Ids 27,32,4199,5719,1014)

# ---------------------------------------------------------------- RESUMO GERAL
Titulo "RESUMO: TOP 20 ERROS/CRÍTICOS DOS ÚLTIMOS $Dias DIAS"
$todos = @()
foreach ($log in 'System','Application') { $todos += Busca-Eventos -Log $log -Level 1,2 }
$todos | Group-Object LogName, ProviderName, Id | Sort-Object Count -Descending | Select-Object -First 20 Count,
    @{n='Origem';e={$_.Name}}, @{n='Ultimo';e={($_.Group | Sort-Object TimeCreated -Descending)[0].TimeCreated}},
    @{n='Exemplo';e={ ($_.Group[0].Message -split "`r?`n")[0] | ForEach-Object { $_.Substring(0,[Math]::Min(100,$_.Length)) } }} |
    Format-Table -AutoSize -Wrap | Out-String -Width 250 | Write-Host

Titulo "ATUALIZAÇÕES RECENTES (driver/patch novo pode ser a causa)"
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 8 HotFixID, Description, InstalledOn | Format-Table -AutoSize | Out-String | Write-Host
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WindowsUpdateClient'; Id=19; StartTime=(Get-Date).AddDays(-15)} |
    Select-Object -First 10 TimeCreated, @{n='Instalado';e={$_.Properties[0].Value}} | Format-Table -AutoSize -Wrap | Out-String -Width 250 | Write-Host

Stop-Transcript | Out-Null
Write-Host "`nRelatório salvo em: $relatorio" -ForegroundColor Green
