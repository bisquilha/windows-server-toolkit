<#
.SYNOPSIS
    Diagnostico do travamento "Please wait for the Local Session Manager" no SERVIDOR01.
    SOMENTE LEITURA. Feito para rodar SEM RDP:
      - do seu PC:   Invoke-Command -ComputerName SERVIDOR01 -FilePath .\Get-LsmDiagnostics.ps1 -Credential DOMINIO\admin
      - ou colando no terminal PowerShell do TacticalRMM / MeshCentral
    Uma copia da saida fica em C:\Temp\DiagLSM_<data>.txt no servidor.
#>
$ErrorActionPreference = 'SilentlyContinue'
$saida = New-Object System.Collections.Generic.List[string]
function W($t) { $saida.Add([string]$t); Write-Output $t }
function T($o) { if ($o) { W (($o | Format-Table -AutoSize -Wrap | Out-String -Width 220).TrimEnd()) } else { W '  (nada)' } }
function S($t) { W ''; W "==== $t  [$(Get-Date -Format 'HH:mm:ss')] ====" }
function ComTimeout([scriptblock]$b, [int]$s = 15) { $j = Start-Job $b; if (Wait-Job $j -Timeout $s) { $r = Receive-Job $j } else { Stop-Job $j; $r = '__TIMEOUT__' }; Remove-Job $j -Force; $r }

$os = Get-CimInstance Win32_OperatingSystem
W "DIAG LSM - $env:COMPUTERNAME - $(Get-Date -Format 'dd/MM/yyyy HH:mm') - ultimo boot $($os.LastBootUpTime) - RAM livre $([math]::Round($os.FreePhysicalMemory/1MB,1)) GB"

S '1. Servicos de sessao'
T (Get-Service LSM, TermService, SessionEnv, UmRdpService, ProfSvc, Spooler, AppReadiness | Select-Object Name, Status, StartType)
$q = ComTimeout { query user 2>&1 } 15
if ("$q" -eq '__TIMEOUT__') { W '  >> query user NAO respondeu em 15 s: Local Session Manager travado' } else { $q | ForEach-Object { W "  $_" } }

S '2. Sessoes (pelos processos) - zumbi = so csrss.exe'
$procs = Get-CimInstance Win32_Process
$sess = $procs | Group-Object SessionId | Sort-Object { [int]$_.Name } | ForEach-Object {
    $exp = $_.Group | Where-Object Name -eq 'explorer.exe' | Select-Object -First 1
    $dono = if ($exp) { $o = Invoke-CimMethod -InputObject $exp -MethodName GetOwner; "$($o.Domain)\$($o.User)" } else { '-' }
    $nomes = $_.Group.Name | Sort-Object -Unique
    $situ = if ($_.Name -eq '0') { 'sistema' } elseif (-not ($nomes | Where-Object { $_ -ne 'csrss.exe' })) { '<<< ZUMBI' } elseif ($nomes -contains 'LogonUI.exe' -and -not $exp) { 'tela de login / logon em andamento' } elseif (-not $exp) { '<<< sem explorer' } else { 'ok' }
    $ini = ($_.Group | Sort-Object CreationDate | Select-Object -First 1).CreationDate
    [pscustomobject]@{ Sessao = $_.Name; Usuario = $dono; Processos = $_.Count; Inicio = $ini; Situacao = $situ; Nomes = (($nomes | Select-Object -First 8) -join ', ') }
}
T $sess

S '3. Eventos do Local Session Manager - ultimas 48 h'
$lsm = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'; StartTime = (Get-Date).AddHours(-48) } -MaxEvents 80
T ($lsm | Sort-Object TimeCreated | Select-Object -Last 45 TimeCreated, Id,
    @{ n = 'Usuario'; e = { if ($_.Message -match 'User:\s*(.+)') { $matches[1].Trim() } } },
    @{ n = 'Sessao'; e = { if ($_.Message -match 'Session ID:\s*(\d+)') { $matches[1] } elseif ($_.Message -match 'Session (\d+)') { $matches[1] } } },
    @{ n = 'Msg'; e = { (($_.Message -split "`n")[0]).Trim() } })

S '4. Servicos que travaram/cairam - ultimas 48 h (7011 timeout, 7022 travou ao iniciar, 7031/7034 caiu, 7046 nao responde)'
$sv = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 7011, 7022, 7031, 7034, 7043, 7046; StartTime = (Get-Date).AddHours(-48) }
T ($sv | Group-Object Id, { (($_.Message -split "`n")[0]) -replace '\d+ time\(s\)', 'N' } | Sort-Object Count -Descending | Select-Object -First 20 Count, @{ n = 'Ultimo'; e = { ($_.Group | Sort-Object TimeCreated -Descending)[0].TimeCreated } }, Name)

S '5. Perfis de usuario - ultimas 48 h (1511/1515 temporario, 1530 registro preso, 1500/1508 falha)'
$pf = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Microsoft-Windows-User Profiles Service'; StartTime = (Get-Date).AddHours(-48) }
T ($pf | Group-Object Id | Select-Object Name, Count, @{ n = 'Ultimo'; e = { ($_.Group | Sort-Object TimeCreated -Descending)[0].TimeCreated } })
$pf | Where-Object Id -eq 1530 | Select-Object -First 3 | ForEach-Object { W "  1530 em $($_.TimeCreated):"; ($_.Message -split "`n" | Where-Object { $_ -match 'Process \d+' } | Select-Object -First 4) | ForEach-Object { W "     $($_.Trim())" } }

S '6. Regras de firewall por usuario (bug do Server 2016 corrigido em 08/10)'
$fw = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy'
W "  FirewallRules: $((Get-Item "$fw\FirewallRules").ValueCount)   Configurable\System: $((Get-Item "$fw\RestrictedServices\Configurable\System").ValueCount)   DeleteUserAppContainersOnLogoff: $((Get-ItemProperty $fw).DeleteUserAppContainersOnLogoff)"
W "  Perfis .bak: $(@(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' | Where-Object PSChildName -like '*.bak').Count)   Pastas TEMP em C:\Users: $(@(Get-ChildItem C:\Users -Directory -Force | Where-Object Name -like 'TEMP*').Count)"

S '7. Disco agora (30 s) - bom < 0,020 s'
$c = Get-Counter '\LogicalDisk(C:)\Avg. Disk sec/Read', '\LogicalDisk(C:)\Avg. Disk sec/Write', '\LogicalDisk(D:)\Avg. Disk sec/Read', '\LogicalDisk(D:)\Avg. Disk sec/Write', '\LogicalDisk(D:)\Disk Reads/sec', '\PhysicalDisk(0 C: D:)\Current Disk Queue Length', '\Processor(_Total)\% Processor Time' -SampleInterval 5 -MaxSamples 6
T ($c.CounterSamples | Group-Object Path | ForEach-Object { $v = $_.Group.CookedValue; [pscustomobject]@{ Contador = ($_.Name -replace '^\\\\[^\\]+\\', ''); Media = [math]::Round(($v | Measure-Object -Average).Average, 3); Max = [math]::Round(($v | Measure-Object -Maximum).Maximum, 3) } })

S '8. Processos - CPU (10 s), memoria e handles'
$p1 = @{}; Get-Process | ForEach-Object { $p1[$_.Id] = $_.CPU }
Start-Sleep 10
$nc = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
T (Get-Process | ForEach-Object { if ($p1.ContainsKey($_.Id) -and $_.CPU) { [pscustomobject]@{ Nome = $_.Name; Id = $_.Id; Sessao = $_.SessionId; 'CPU%' = [math]::Round(100 * ($_.CPU - $p1[$_.Id]) / 10 / $nc, 1); RAM_MB = [math]::Round($_.WS / 1MB); Handles = $_.Handles } } } | Sort-Object 'CPU%' -Descending | Select-Object -First 12)
T (Get-Process | Sort-Object Handles -Descending | Select-Object -First 6 Name, Id, SessionId, Handles)
$sv2 = Get-CimInstance Win32_Service | Where-Object { $_.Name -in 'LSM', 'TermService', 'Spooler', 'ProfSvc' }
foreach ($s in $sv2) { $pr = Get-Process -Id $s.ProcessId; W ("  {0,-12} PID {1,-6} handles {2,-6} threads {3}" -f $s.Name, $s.ProcessId, $pr.Handles, $pr.Threads.Count) }

S '9. SQL e impressao'
$pp = Get-Counter -ListSet '*Buffer Manager*', '*Memory Manager*' | ForEach-Object { $_.Paths } | Where-Object { $_ -match 'Page life expectancy|Total Server Memory' }
T ((Get-Counter $pp).CounterSamples | Select-Object @{ n = 'Contador'; e = { $_.Path -replace '^\\\\[^\\]+\\', '' } }, @{ n = 'Valor'; e = { [math]::Round($_.CookedValue) } })
W "  Impressoras instaladas: $(@(Get-Printer).Count)   Redirecionadas (RDP): $(@(Get-Printer | Where-Object { $_.Name -match 'redirect|redirecionad' }).Count)   Trabalhos na fila: $(@(Get-Printer | ForEach-Object { Get-PrintJob -PrinterObject $_ }).Count)"

S '10. Desligamentos e reinicios - 8 dias'
T (Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41, 1074, 6005, 6006, 6008; StartTime = (Get-Date).AddDays(-8) } | Select-Object -First 15 TimeCreated, Id, @{ n = 'Msg'; e = { $m = (($_.Message -split "`n")[0]).Trim(); $m.Substring(0, [Math]::Min(120, $m.Length)) } })

New-Item -ItemType Directory -Force C:\Temp | Out-Null
$arq = "C:\Temp\DiagLSM_$(Get-Date -Format 'yyyyMMdd_HHmm').txt"
$saida | Out-File $arq -Encoding UTF8
W ''; W "Copia salva no servidor: $arq"
