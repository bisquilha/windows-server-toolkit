<#
.SYNOPSIS
    Checklist pré-reboot do servidor. Só LÊ, exceto o tamanho dos logs de eventos (item 1).
    Saída em C:\Temp\PreReboot_<data>.txt
#>
$ErrorActionPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force C:\Temp | Out-Null
Start-Transcript "C:\Temp\PreReboot_$(Get-Date -Format 'yyyyMMdd_HHmm').txt" -Force | Out-Null
function Titulo($t) { Write-Host "`n==== $t ====" -ForegroundColor Cyan }

# ------------------------------------------------------------ 1. LOGS (única alteração)
Titulo "1. Aumentando logs de eventos (System 128MB / Application 64MB)"
wevtutil sl System /ms:134217728
wevtutil sl Application /ms:67108864
Get-WinEvent -ListLog System, Application | Select-Object LogName, @{n='MaxMB';e={$_.MaximumSizeInBytes/1MB}}, @{n='UsoMB';e={[math]::Round($_.FileSize/1MB,1)}} | Format-Table -AutoSize | Out-String | Write-Host

# ------------------------------------------------------------ 2. WINDOWS SEARCH
Titulo "2. Windows Search - loop parou?"
Get-Service WSearch | Select-Object Status, StartType | Format-Table -AutoSize | Out-String | Write-Host
$n = (Get-WinEvent -FilterHashtable @{LogName='System'; Id=7000,7009,10005; StartTime=(Get-Date).AddMinutes(-5)} | Measure-Object).Count
Write-Host ("  Eventos 7000/7009/10005 nos últimos 5 min: {0}" -f $n) -ForegroundColor Yellow
Get-WinEvent -FilterHashtable @{LogName='System'; Id=10005; StartTime=(Get-Date).AddMinutes(-5)} -MaxEvents 1 | Select-Object -ExpandProperty Message | Write-Host

# ------------------------------------------------------------ 3. RAID
Titulo "3. Controladora RAID (MegaRAID)"
$storcli = @('C:\Program Files\LSI\StorCLI\storcli64.exe','C:\Program Files (x86)\LSI\StorCLI\storcli64.exe',
             'C:\Program Files\MegaRAID\StorCLI\storcli64.exe','C:\storcli64.exe',
             'C:\Program Files\LSI\LSIStorageAuthority\server\bin\storcli64.exe',
             'C:\Program Files (x86)\MegaRAID Storage Manager\StorCLI64.exe') |
           Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if ($storcli) {
    Write-Host "  storcli: $storcli"
    & $storcli /c0 show | Write-Host
    & $storcli /c0/vall show all | Select-String 'State|Cache|Consist|Rebuild|BGI|Access|Size|TYPE' | Write-Host
    & $storcli /c0/eall/sall show all | Select-String 'Slot|State|Media Error|Other Error|Predictive|S.M.A.R.T|Model|Firmware' | Write-Host
    & $storcli /c0 show cc | Write-Host
    & $storcli /c0 show patrolread | Write-Host
    & $storcli /c0/vall show rebuild | Write-Host
} else {
    Write-Host "  storcli não encontrado. Ferramentas instaladas relacionadas a RAID:" -ForegroundColor Yellow
    Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*, HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* |
        Where-Object { $_.DisplayName -match 'LSI|MegaRAID|Storage Authority|Avago|Broadcom|ThinkServer|TSM|EasyManage' } |
        Select-Object DisplayName, DisplayVersion, InstallLocation | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
}
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='megasas*','MegaSas*','lsi_*','percsas*'; StartTime=(Get-Date).AddDays(-7)} -MaxEvents 20 |
    Select-Object TimeCreated, ProviderName, Id, @{n='Msg';e={($_.Message -split "`r?`n")[0]}} | Format-Table -AutoSize -Wrap | Out-String -Width 250 | Write-Host
Get-PhysicalDisk | Get-StorageReliabilityCounter | Select-Object DeviceId, ReadErrorsTotal, WriteErrorsTotal, ReadLatencyMax, WriteLatencyMax, PowerOnHours | Format-Table -AutoSize | Out-String | Write-Host

# ------------------------------------------------------------ 4. ANTIVÍRUS PÓS-KASPERSKY
Titulo "4. Restos do Kaspersky / Defender"
Get-Service | Where-Object { $_.DisplayName -match 'Kaspersky|AVP|klnagent' -or $_.Name -match '^(klnagent|AVP|kl)' } |
    Select-Object Name, DisplayName, Status, StartType | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
Get-CimInstance Win32_SystemDriver | Where-Object { $_.Name -match '^kl|^kne|^cm_km' } | Select-Object Name, State, StartMode | Format-Table -AutoSize | Out-String | Write-Host
Get-WindowsFeature Windows-Defender* | Select-Object Name, InstallState | Format-Table -AutoSize | Out-String | Write-Host
Get-Service WinDefend | Select-Object Status, StartType | Format-Table -AutoSize | Out-String | Write-Host
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' | Select-Object DisableAntiSpyware | Format-List | Out-String | Write-Host

# ------------------------------------------------------------ 5. CAMINHOS PARA EXCLUSÕES (SQL + Protheus)
Titulo "5. SQL Server - arquivos de banco"
$sqlcmd = Get-Command sqlcmd.exe | Select-Object -ExpandProperty Source
if ($sqlcmd) {
    & $sqlcmd -S . -E -W -s '|' -Q 'SET NOCOUNT ON; SELECT DB_NAME(database_id) AS db, type_desc, physical_name, size/128 AS MB FROM sys.master_files ORDER BY size DESC' | Write-Host
} else { Write-Host "  sqlcmd não encontrado" -ForegroundColor Yellow }
Get-CimInstance Win32_Service | Where-Object { $_.Name -match 'MSSQL|SQLAgent|SQLServer' } | Select-Object Name, State, PathName | Format-Table -AutoSize -Wrap | Out-String -Width 250 | Write-Host

Titulo "5b. Protheus - serviços appserver/dbaccess/license"
Get-CimInstance Win32_Service | Where-Object { $_.PathName -match 'appserver|dbaccess|totvs|protheus|license' -or $_.Name -match 'APPSERVER|DBACCESS|TOTVS|LICENSE' } |
    Select-Object Name, State, StartMode, PathName | Format-Table -AutoSize -Wrap | Out-String -Width 300 | Write-Host

# ------------------------------------------------------------ 6. PERFIS TEMPORÁRIOS
Titulo "6. Perfis corrompidos (.bak no ProfileList) e pastas TEMP"
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' | ForEach-Object {
    $p = Get-ItemProperty $_.PSPath
    if ($_.PSChildName -like '*.bak' -or $p.ProfileImagePath -match 'TEMP' -or $p.State -ne 0) {
        $sid = $_.PSChildName -replace '\.bak$',''
        $user = try { (New-Object Security.Principal.SecurityIdentifier $sid).Translate([Security.Principal.NTAccount]).Value } catch { '?' }
        [pscustomobject]@{ Chave=$_.PSChildName; Usuario=$user; Caminho=$p.ProfileImagePath; State=$p.State; RefCount=$p.RefCount }
    }
} | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
Get-ChildItem C:\Users -Directory | Where-Object Name -like 'TEMP*' | Select-Object Name, LastWriteTime | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "  Sessões abertas:"; query user 2>$null | Write-Host

# ------------------------------------------------------------ 7. REBOOT PENDENTE
Titulo "7. Reboot pendente"
[pscustomobject]@{
    WindowsUpdate   = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    CBS             = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    RenamePendente  = [bool](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager').PendingFileRenameOperations
} | Format-List | Out-String | Write-Host

# ------------------------------------------------------------ 8. DISCO AGORA
Titulo "8. Latência agora (30s)"
Get-Counter '\PhysicalDisk(*)\Avg. Disk sec/Read','\PhysicalDisk(*)\Avg. Disk sec/Write','\PhysicalDisk(*)\Current Disk Queue Length' -SampleInterval 5 -MaxSamples 6 |
  ForEach-Object { $_.CounterSamples | Where-Object { $_.InstanceName -ne '_total' -and $_.CookedValue -gt 0 } |
  Select-Object @{n='Hora';e={$_.Timestamp.ToString('HH:mm:ss')}}, @{n='Contador';e={$_.Path -replace '^.*physicaldisk',''}}, @{n='Valor';e={[math]::Round($_.CookedValue,3)}} } |
  Format-Table -AutoSize | Out-String | Write-Host
Write-Host "  Top processos por I/O de disco:"
Get-Counter '\Process(*)\IO Data Bytes/sec' | Select-Object -ExpandProperty CounterSamples | Where-Object { $_.InstanceName -notin '_total','idle' } |
    Sort-Object CookedValue -Descending | Select-Object -First 10 InstanceName, @{n='MB/s';e={[math]::Round($_.CookedValue/1MB,2)}} | Format-Table -AutoSize | Out-String | Write-Host

Stop-Transcript | Out-Null
