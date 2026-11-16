<#
.SYNOPSIS
    CHECKUP GERAL - servidor de producao SERVIDOR01 (Protheus + SQL Server + RDP).
    SOMENTE LEITURA: nao altera configuracao, nao inicia/para servicos e nao mexe em nada da TOTVS.
.DESCRIPTION
    Gera a pasta C:\Temp\Checkup_<host>_<data>\ com:
      checkup.txt  - relatorio completo
      alertas.csv  - lista de achados (CRITICO / ATENCAO / INFO)
      sel_bmc.csv  - log de hardware da placa de gerencia (se disponivel)
    Duracao tipica: 15-30 min (tamanho de pastas e amostra de desempenho sao as partes longas).
.PARAMETER SqlUser
    Login SQL com permissao de leitura (ex.: sa). A senha e pedida na tela e nao fica gravada.
    Sem ele, tenta autenticacao do Windows; sem acesso, faz so a parte "por fora" do SQL.
.PARAMETER PularTamanhos
    Nao calcula o tamanho das pastas (use se estiver demorando demais).
.PARAMETER Integridade
    Roda SOMENTE as verificacoes de integridade: sfc /verifyonly, DISM /ScanHealth e chkdsk /scan.
    Nao corrige nada, mas leva 30-90 min e le muito o disco (fazer com o servidor livre).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Downloads\Invoke-ServerCheckup.ps1"
    powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Downloads\Invoke-ServerCheckup.ps1" -SqlUser sa
    powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Downloads\Invoke-ServerCheckup.ps1" -Integridade
#>
param(
    [string]$SqlUser,
    [switch]$PularTamanhos,
    [switch]$Integridade
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'
$inicioExec = Get-Date
$outDir = "C:\Temp\Checkup_$($env:COMPUTERNAME)_$(Get-Date -Format 'yyyyMMdd_HHmm')"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$arqTxt = Join-Path $outDir $(if ($Integridade) { 'integridade.txt' } else { 'checkup.txt' })
Start-Transcript -Path $arqTxt -Force | Out-Null

# ================================ utilitarios ================================
$script:Alertas = New-Object System.Collections.Generic.List[object]
function Alerta([string]$Nivel, [string]$Area, [string]$Texto) {
    $script:Alertas.Add([pscustomobject]@{ Nivel = $Nivel; Area = $Area; Achado = $Texto })
    $cor = switch ($Nivel) { 'CRITICO' { 'Red' } 'ATENCAO' { 'Yellow' } default { 'Gray' } }
    Write-Host "  >> [$Nivel] $Texto" -ForegroundColor $cor
}
function Secao([string]$t) { Write-Host ("`n" + ('=' * 20) + " $t  [$(Get-Date -Format 'HH:mm:ss')] " + ('=' * 20)) -ForegroundColor Cyan }
function Sub([string]$t)   { Write-Host "`n--- $t ---" -ForegroundColor DarkCyan }
function Tab($o) {
    if ($o) { $o | Format-Table -AutoSize -Wrap | Out-String -Width 300 | Write-Host }
    else    { Write-Host '  (nada)' -ForegroundColor DarkGray }
}
function Lst($o) { if ($o) { $o | Format-List | Out-String -Width 300 | Write-Host } }
function Ev([string]$Log, [int[]]$Id, [int]$Dias = 30, [string[]]$Provider, [int[]]$Level) {
    $f = @{ LogName = $Log; StartTime = (Get-Date).AddDays(-$Dias) }
    if ($Id)       { $f.Id = $Id }
    if ($Provider) { $f.ProviderName = $Provider }
    if ($Level)    { $f.Level = $Level }
    @(Get-WinEvent -FilterHashtable $f -ErrorAction SilentlyContinue)
}
function Msg1($e, [int]$n = 140) {
    $m = (($e.Message -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
    if (-not $m) { $m = '(sem texto) ' + (($e.Properties | ForEach-Object { $_.Value }) -join ' | ') }
    $m = ("$m" -replace '\s+', ' ').Trim()
    if ($m.Length -gt $n) { $m.Substring(0, $n) + '...' } else { $m }
}
function ComTimeout([scriptblock]$Bloco, [int]$Seg = 20) {
    $j = Start-Job -ScriptBlock $Bloco
    if (Wait-Job $j -Timeout $Seg) { $r = Receive-Job $j } else { Stop-Job $j; $r = '__TIMEOUT__' }
    Remove-Job $j -Force
    $r
}
function Rodar([string]$Nome, [scriptblock]$Bloco) {
    try { & $Bloco } catch { Write-Host "  [falha na secao '$Nome': $($_.Exception.Message)]" -ForegroundColor Red }
}
function TamanhoPasta([string]$p) {
    $o = robocopy "$p" "$env:TEMP\__checkup_nao_existe__" /L /S /XJ /BYTES /NJH /NFL /NDL /NC /NP /R:0 /W:0 2>$null
    $b = $o | Select-String '^\s*Bytes\s*:\s*(\d+)' | Select-Object -First 1
    $f = $o | Select-String '^\s*(Files|Arquivos)\s*:\s*(\d+)' | Select-Object -First 1
    [pscustomobject]@{
        Pasta    = $p
        GB       = if ($b) { [math]::Round([double]$b.Matches[0].Groups[1].Value / 1GB, 1) } else { $null }
        Arquivos = if ($f) { [int64]$f.Matches[0].Groups[2].Value } else { $null }
    }
}
function DataLinha([string]$l) { if ($l -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') { [datetime]$matches[1] } }
function Finaliza {
    Secao 'RESUMO DE ALERTAS'
    $ord = @{ 'CRITICO' = 0; 'ATENCAO' = 1; 'INFO' = 2 }
    $al = @($script:Alertas | Sort-Object @{ e = { $ord[$_.Nivel] } }, Area)
    Tab ($al | Select-Object Nivel, Area, Achado)
    $csv = Join-Path $outDir $(if ($Integridade) { 'alertas_integridade.csv' } else { 'alertas.csv' })
    $al | Export-Csv $csv -NoTypeInformation -Encoding UTF8
    Write-Host ("  Total: {0} CRITICO | {1} ATENCAO | {2} INFO" -f @($al | Where-Object Nivel -eq 'CRITICO').Count, @($al | Where-Object Nivel -eq 'ATENCAO').Count, @($al | Where-Object Nivel -eq 'INFO').Count)
    Write-Host "  Duracao: $([math]::Round(((Get-Date) - $inicioExec).TotalMinutes, 1)) min"
    Write-Host "  Arquivos gerados em: $outDir" -ForegroundColor Green
    Stop-Transcript | Out-Null
}

# ================================ contexto ================================
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "CHECKUP GERAL - $env:COMPUTERNAME - $(Get-Date -Format 'dd/MM/yyyy HH:mm') - usuario $env:USERDOMAIN\$env:USERNAME - modo: $(if ($Integridade) { 'INTEGRIDADE' } else { 'COMPLETO' })"
Write-Host 'Somente leitura: nenhuma configuracao e alterada.'
if (-not $admin) { Write-Host 'ERRO: abra o PowerShell como Administrador.' -ForegroundColor Red; Stop-Transcript | Out-Null; return }

# ================================ modo integridade ================================
if ($Integridade) {
    Secao 'INTEGRIDADE 1/3 - arquivos de sistema (sfc /verifyonly)'
    $o = @(cmd /c 'sfc /verifyonly' 2>&1 | ForEach-Object { ("$_" -replace "`0", '').Trim() } | Where-Object { $_ })
    $o | Select-Object -Last 4 | ForEach-Object { Write-Host "  $_" }
    if ($o -match 'found integrity violations|encontrou viola') { Alerta 'CRITICO' 'Windows' 'SFC encontrou arquivos de sistema corrompidos (ver C:\Windows\Logs\CBS\CBS.log)' }
    elseif ($o -match 'did not find any integrity violations|o encontrou nenhuma') { Write-Host '  OK' -ForegroundColor Green }
    else { Alerta 'ATENCAO' 'Windows' 'SFC nao concluiu ou o resultado nao foi reconhecido (ver saida acima)' }

    Secao 'INTEGRIDADE 2/3 - imagem do Windows (DISM /ScanHealth)'
    $o = @(DISM.exe /Online /Cleanup-Image /ScanHealth 2>&1 | Where-Object { $_ -and "$_" -notmatch '^\s*\[' })
    $o | Select-Object -Last 4 | ForEach-Object { Write-Host "  $_" }
    if ($o -match 'not repairable') { Alerta 'CRITICO' 'Windows' 'Repositorio de componentes do Windows corrompido e NAO reparavel' }
    elseif ($o -match 'is repairable') { Alerta 'ATENCAO' 'Windows' 'Repositorio de componentes do Windows corrompido (reparavel com DISM /RestoreHealth)' }
    elseif ($o -match 'No component store corruption') { Write-Host '  OK' -ForegroundColor Green }
    else { Alerta 'ATENCAO' 'Windows' 'DISM nao concluiu ou o resultado nao foi reconhecido' }

    foreach ($v in @(Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystem -eq 'NTFS' -and $_.Size -gt 0 } | Sort-Object DriveLetter)) {
        $L = "$($v.DriveLetter):"
        Secao "INTEGRIDADE 3/3 - chkdsk $L /scan (so leitura)"
        $o = @(cmd /c "chkdsk $L /scan" 2>&1)
        $o | Where-Object { "$_" -match 'Windows has|found no problems|problem|corrupt|bad sectors|errors' } | Select-Object -Last 8 | ForEach-Object { Write-Host "  $_" }
        $bad = $o | Select-String '(\d+) KB in bad sectors' | Select-Object -First 1
        if ($bad -and [int64]$bad.Matches[0].Groups[1].Value -gt 0) { Alerta 'CRITICO' 'Armazenamento' "Volume $L com setores defeituosos ($($bad.Matches[0].Groups[1].Value) KB)" }
        if ($o -match 'found no problems') { Write-Host '  OK' -ForegroundColor Green }
        elseif ($o -match 'found problems|must be fixed offline|corruption') { Alerta 'CRITICO' 'Armazenamento' "chkdsk encontrou problemas no volume $L - agendar correcao offline" }
        else { Alerta 'ATENCAO' 'Armazenamento' "chkdsk em $L sem resultado conclusivo (ver saida)" }
    }
    Finaliza
    return
}


# ================================ 1. IDENTIFICACAO ================================
Secao '1. IDENTIFICACAO E DISPONIBILIDADE'
Rodar 'identificacao' {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $ubr = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR
    $up = (Get-Date) - $os.LastBootUpTime
    Lst ([pscustomobject]@{
        Servidor    = $env:COMPUTERNAME
        Dominio     = $cs.Domain
        SO          = "$($os.Caption) - build $($os.BuildNumber).$ubr"
        InstaladoEm = $os.InstallDate
        Hardware    = "$($cs.Manufacturer) $($cs.Model)"
        NumeroSerie = $bios.SerialNumber
        BIOS        = "$($bios.SMBIOSBIOSVersion) de $(if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString('dd/MM/yyyy') })"
        RAM_GB      = [math]::Round($cs.TotalPhysicalMemory / 1GB)
        UltimoBoot  = $os.LastBootUpTime
        Uptime      = '{0}d {1}h {2}m' -f $up.Days, $up.Hours, $up.Minutes
        FusoHorario = (Get-TimeZone).Id
    })
    if ($os.Caption -match '2016') {
        $dias = ([datetime]'2027-01-12' - (Get-Date)).Days
        Alerta 'ATENCAO' 'Windows' "Windows Server 2016: suporte estendido da Microsoft termina em 12/01/2027 (faltam $dias dias) - planejar migracao"
    }
    Sub 'Inicializacoes e desligamentos - 30 dias'
    $ev = Ev System @(41, 1001, 1074, 1076, 6005, 6006, 6008) 30 | Where-Object { $_.Id -ne 1001 -or $_.ProviderName -match 'WER-SystemErrorReporting' }
    Tab ($ev | Sort-Object TimeCreated -Descending | Select-Object -First 30 TimeCreated, Id, ProviderName, @{ n = 'Mensagem'; e = { Msg1 $_ 130 } })
    $kp = @($ev | Where-Object { $_.Id -eq 41 }); $bs = @($ev | Where-Object { $_.Id -eq 1001 }); $bt = @($ev | Where-Object { $_.Id -eq 6005 })
    Write-Host "  Inicializacoes: $($bt.Count) | Desligamentos abruptos (41): $($kp.Count) | Telas azuis (1001): $($bs.Count)"
    if ($kp.Count) { Alerta 'CRITICO' 'Disponibilidade' "$($kp.Count) desligamento(s) abrupto(s) (Kernel-Power 41) em 30 dias - ultimo em $($kp[0].TimeCreated.ToString('dd/MM HH:mm'))" }
    if ($bs.Count) { Alerta 'CRITICO' 'Disponibilidade' "$($bs.Count) tela(s) azul(is) em 30 dias" }
    if ($bt.Count -gt 4) { Alerta 'ATENCAO' 'Disponibilidade' "$($bt.Count) reinicializacoes em 30 dias (servidor de producao)" }
}

# ================================ 2. HARDWARE ================================
Secao '2. HARDWARE'
Rodar 'cpu-memoria' {
    Sub 'Processadores'
    Tab (Get-CimInstance Win32_Processor | Select-Object DeviceID, Name, NumberOfCores, NumberOfLogicalProcessors, @{ n = 'MaxMHz'; e = { $_.MaxClockSpeed } }, @{ n = 'AtualMHz'; e = { $_.CurrentClockSpeed } }, @{ n = 'Uso%'; e = { $_.LoadPercentage } })
    Write-Host "  Plano de energia do Windows: $(powercfg /getactivescheme)"
    $thr = Ev System 37 30 -Provider 'Microsoft-Windows-Kernel-Processor-Power'
    if ($thr.Count) { Alerta 'ATENCAO' 'Hardware' "CPU limitada pelo firmware: $($thr.Count) eventos (Kernel-Processor-Power 37) em 30 dias - ajustar perfil de energia no BIOS para Maximum Performance" }
    Sub 'Memoria (pentes)'
    Tab (Get-CimInstance Win32_PhysicalMemory | Select-Object DeviceLocator, BankLabel, @{ n = 'GB'; e = { [math]::Round($_.Capacity / 1GB) } }, Speed, ConfiguredClockSpeed, Manufacturer, PartNumber)
    Sub 'Dispositivos com problema no Gerenciador de Dispositivos'
    $pnp = @(Get-PnpDevice -PresentOnly | Where-Object { $_.Status -ne 'OK' })
    Tab ($pnp | Select-Object Class, FriendlyName, Status, InstanceId)
    $pnpRuim = @($pnp | Where-Object { $_.Status -in 'Error', 'Degraded' })
    if ($pnpRuim.Count) { Alerta 'ATENCAO' 'Hardware' "$($pnpRuim.Count) dispositivo(s) com erro no Gerenciador de Dispositivos: $(($pnpRuim.FriendlyName | Select-Object -First 5) -join ', ')" }
    Sub 'Drivers de controladora de disco e rede'
    Tab (Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceClass -in 'SCSIADAPTER', 'NET', 'HDC' -and $_.DeviceName } | Sort-Object DeviceClass, DeviceName | Select-Object DeviceClass, DeviceName, DriverVersion, @{ n = 'Data'; e = { if ($_.DriverDate) { $_.DriverDate.ToString('dd/MM/yyyy') } } }, Manufacturer)
}


Rodar 'bmc' {
    Sub 'Placa de gerencia (BMC/TSM) via IPMI'
    $ipmi = Get-WmiObject -Namespace root\wmi -Class Microsoft_IPMI
    if (-not $ipmi) { Write-Host '  Driver IPMI indisponivel - pulando'; return }
    function Ipmi([int]$NetFn, [int]$Cmd, [byte[]]$Dados) {
        $in = $ipmi.GetMethodParameters('RequestResponse')
        $in.NetworkFunction = $NetFn; $in.Lun = 0; $in.ResponderAddress = 0x20; $in.Command = $Cmd
        if ($Dados -and $Dados.Length -gt 0) { $in.RequestData = $Dados; $in.RequestDataSize = $Dados.Length }
        else { $in.RequestData = [byte[]]@(0); $in.RequestDataSize = 0 }
        $r = $ipmi.InvokeMethod('RequestResponse', $in, $null)
        , ([byte[]]$r.ResponseData)
    }

    $d = Ipmi 0x06 0x01 @()
    if ($d -and $d.Length -ge 6 -and $d[0] -eq 0) { Write-Host ("  Firmware do BMC: {0}.{1:X2}   IPMI {2}.{3}" -f ($d[3] -band 0x7F), $d[4], ($d[5] -band 0x0F), ($d[5] -shr 4)) }

    $st = Ipmi 0x06 0x04 @()
    if ($st -and $st.Length -ge 2 -and $st[0] -eq 0) {
        $txt = switch ($st[1]) { 0x55 { 'OK (sem erros)' } 0x56 { 'nao implementado' } 0x57 { 'FALHA em componente do BMC' } 0x58 { 'ERRO FATAL de hardware no BMC' } default { 'codigo 0x{0:X2}' -f $st[1] } }
        Write-Host "  Autoteste do BMC: $txt"
        if ($st[1] -eq 0x57) { Alerta 'ATENCAO' 'Hardware (BMC)' ("Autoteste da placa de gerencia indicou falha (detalhe 0x{0:X2})" -f $st[2]) }
        if ($st[1] -eq 0x58) { Alerta 'CRITICO' 'Hardware (BMC)' 'Autoteste da placa de gerencia: erro fatal de hardware' }
    }

    $c = Ipmi 0x00 0x01 @()
    if ($c -and $c.Length -ge 4 -and $c[0] -eq 0) {
        $p = $c[1]; $u = $c[2]; $m = $c[3]
        $pol = switch (($p -shr 5) -band 3) { 0 { 'fica DESLIGADO' } 1 { 'volta ao estado anterior' } 2 { 'liga sempre' } default { 'desconhecida' } }
        $ult = (@(@{ b = 1; t = 'queda de AC' }, @{ b = 2; t = 'sobrecarga' }, @{ b = 4; t = 'interlock' }, @{ b = 8; t = 'falha de energia' }, @{ b = 0x10; t = 'ligado via IPMI' }) | Where-Object { $u -band $_.b } | ForEach-Object { $_.t }) -join ', '
        Lst ([pscustomobject]@{
            Ligado = [bool]($p -band 1); SobrecargaEnergia = [bool]($p -band 2); FalhaEnergia = [bool]($p -band 8); FalhaControleEnergia = [bool]($p -band 0x10)
            AposQuedaDeEnergia = $pol; UltimoEventoEnergia = $ult
            FalhaDeDisco = [bool]($m -band 4); FalhaDeVentilacao = [bool]($m -band 8); IntrusaoGabinete = [bool]($m -band 1)
        })
        if ($p -band 0x1A) { Alerta 'CRITICO' 'Hardware (BMC)' 'BMC indica falha/sobrecarga de energia (chassis status)' }
        if ($m -band 4) { Alerta 'CRITICO' 'Hardware (BMC)' 'BMC indica FALHA DE DISCO (chassis status)' }
        if ($m -band 8) { Alerta 'CRITICO' 'Hardware (BMC)' 'BMC indica falha de VENTILACAO/refrigeracao' }
        if ((($p -shr 5) -band 3) -eq 0) { Alerta 'ATENCAO' 'Hardware (BMC)' 'Apos queda de energia o servidor fica DESLIGADO (power restore policy) - avaliar "voltar ao estado anterior"' }
    }

    foreach ($ch in 1..8) {
        $ip = Ipmi 0x0C 0x02 ([byte[]]@($ch, 3, 0, 0))
        if ($ip -and $ip.Length -ge 6 -and $ip[0] -eq 0) {
            $ipStr = ($ip[2..5]) -join '.'
            if ($ipStr -ne '0.0.0.0') {
                $ok = Test-Connection $ipStr -Count 1 -Quiet
                Write-Host "  Rede do BMC (canal $ch): $ipStr - responde a ping: $ok"
                if (-not $ok) { Alerta 'ATENCAO' 'Hardware (BMC)' "Gerencia remota (TSM) em $ipStr nao responde - sem acesso remoto a console e log de hardware" }
            }
        }
    }

    Sub 'Log de hardware do BMC (SEL)'
    $inf = Ipmi 0x0A 0x40 @()
    if (-not ($inf -and $inf.Length -ge 15 -and $inf[0] -eq 0)) { Write-Host '  SEL indisponivel'; return }
    $qtd = [BitConverter]::ToUInt16($inf, 2); $livre = [BitConverter]::ToUInt16($inf, 4); $overflow = ($inf[14] -band 0x80) -ne 0
    Write-Host "  Registros: $qtd   Espaco livre: $livre bytes   Overflow: $overflow"
    if ($overflow -or $livre -lt 800) { Alerta 'ATENCAO' 'Hardware (BMC)' 'Log de hardware do BMC (SEL) cheio ou quase cheio - eventos novos podem ser perdidos (exportar e limpar)' }

    $epoch = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
    $ajuste = 0
    $tsel = Ipmi 0x0A 0x48 @()
    if ($tsel -and $tsel.Length -ge 5 -and $tsel[0] -eq 0) {
        $ajuste = [double][DateTimeOffset]::Now.ToUnixTimeSeconds() - [BitConverter]::ToUInt32($tsel, 1)
        Write-Host ("  Relogio do BMC difere do Windows em {0:N1} h (horarios abaixo ja corrigidos)" -f ($ajuste / 3600))
    }

    $tipos = @{ 1 = 'Temperatura'; 2 = 'Tensao'; 3 = 'Corrente'; 4 = 'Ventilador'; 5 = 'Seguranca fisica'; 7 = 'Processador'; 8 = 'Fonte (PSU)'; 9 = 'Unidade de energia'; 12 = 'Memoria'; 13 = 'Slot de disco'; 15 = 'POST/Firmware'; 16 = 'Log de eventos'; 18 = 'Evento de sistema'; 19 = 'Interrupcao critica'; 20 = 'Botao'; 21 = 'Placa/modulo'; 25 = 'Chipset'; 27 = 'Cabo'; 29 = 'Boot/Reinicio'; 31 = 'Boot do SO'; 32 = 'Parada do SO'; 33 = 'Slot/Conector'; 34 = 'Estado ACPI'; 35 = 'Watchdog'; 40 = 'Subsistema de gerencia'; 43 = 'Mudanca de versao' }
    $esp = @{
        '7-0' = 'IERR (erro interno do processador)|CRITICO'; '7-1' = 'Thermal Trip (superaquecimento)|CRITICO'; '7-5' = 'Erro de configuracao|ATENCAO'; '7-7' = 'Processador presente|INFO'; '7-10' = 'Processador limitado (throttled)|ATENCAO'; '7-11' = 'Machine Check Exception|CRITICO'
        '8-0' = 'Fonte presente|INFO'; '8-1' = 'FALHA na fonte|CRITICO'; '8-2' = 'Falha prevista na fonte|CRITICO'; '8-3' = 'Fonte sem energia AC|CRITICO'; '8-4' = 'Fonte com AC perdido/fora da faixa|CRITICO'; '8-5' = 'AC fora da faixa|ATENCAO'; '8-6' = 'Erro de configuracao da fonte|ATENCAO'
        '9-0' = 'Desligado|INFO'; '9-1' = 'Ciclo de energia|INFO'; '9-4' = 'Perda de energia AC|CRITICO'; '9-5' = 'Falha no controle de energia|CRITICO'; '9-6' = 'Falha na unidade de energia|CRITICO'; '9-7' = 'Falha prevista na energia|CRITICO'
        '12-0' = 'Erro de memoria ECC corrigivel|ATENCAO'; '12-1' = 'Erro de memoria ECC NAO corrigivel|CRITICO'; '12-2' = 'Erro de paridade de memoria|CRITICO'; '12-3' = 'Falha no memory scrub|CRITICO'; '12-4' = 'Pente de memoria desativado|CRITICO'; '12-5' = 'Limite de log de ECC corrigivel atingido|ATENCAO'; '12-6' = 'Memoria presente|INFO'; '12-7' = 'Erro de configuracao de memoria|ATENCAO'; '12-10' = 'Memoria superaquecida|CRITICO'
        '13-0' = 'Disco presente|INFO'; '13-1' = 'FALHA de disco|CRITICO'; '13-2' = 'Falha prevista de disco|CRITICO'; '13-3' = 'Hot spare|INFO'; '13-4' = 'Consistency check em andamento|INFO'; '13-5' = 'Disco em array degradado|CRITICO'; '13-6' = 'Disco em array com falha|CRITICO'; '13-7' = 'Rebuild em andamento|ATENCAO'; '13-8' = 'Rebuild abortado|CRITICO'
        '15-0' = 'Erro de firmware no POST|ATENCAO'; '15-1' = 'Travamento no POST|CRITICO'
        '16-0' = 'Log de memoria corrigivel desativado|ATENCAO'; '16-2' = 'SEL limpo|INFO'; '16-4' = 'SEL CHEIO|ATENCAO'; '16-5' = 'SEL quase cheio|ATENCAO'
        '18-0' = 'Sistema reconfigurado|INFO'; '18-1' = 'Boot do sistema|INFO'; '18-2' = 'Falha de hardware indeterminada|CRITICO'; '18-5' = 'Sincronizacao de relogio|INFO'
        '19-0' = 'NMI do painel frontal|ATENCAO'; '19-1' = 'Timeout de barramento|CRITICO'; '19-2' = 'NMI de I/O|CRITICO'; '19-3' = 'NMI de software|ATENCAO'; '19-4' = 'PCI PERR|CRITICO'; '19-5' = 'PCI SERR|CRITICO'; '19-7' = 'Erro corrigivel de barramento|ATENCAO'; '19-8' = 'Erro NAO corrigivel de barramento|CRITICO'; '19-9' = 'NMI fatal|CRITICO'; '19-10' = 'Erro fatal de barramento|CRITICO'
        '29-0' = 'Ligado|INFO'; '29-1' = 'Reset forcado (hard reset)|ATENCAO'; '29-2' = 'Reset a quente|INFO'; '29-7' = 'Reinicio do sistema|INFO'
        '32-0' = 'Parada critica na carga do SO|CRITICO'; '32-1' = 'Parada critica do SO (tela azul)|CRITICO'; '32-2' = 'Parada normal do SO|INFO'; '32-3' = 'Desligamento normal do SO|INFO'
        '35-0' = 'Watchdog expirou|CRITICO'; '35-1' = 'Watchdog: hard reset|CRITICO'; '35-2' = 'Watchdog: desligamento|CRITICO'; '35-3' = 'Watchdog: ciclo de energia|CRITICO'
    }
    $lim = 'abaixo do limite nao-critico', 'abaixo do nao-critico', 'abaixo do limite CRITICO', 'abaixo do critico', 'abaixo do limite IRRECUPERAVEL', 'abaixo do irrecuperavel', 'acima do nao-critico', 'acima do limite nao-critico', 'acima do critico', 'acima do limite CRITICO', 'acima do irrecuperavel', 'acima do limite IRRECUPERAVEL'
    $sev = 'voltou ao normal|INFO', 'nao-critico|ATENCAO', 'CRITICO|CRITICO', 'IRRECUPERAVEL|CRITICO', 'nao-critico (melhorando)|ATENCAO', 'critico (melhorando)|CRITICO', 'irrecuperavel|CRITICO', 'monitorar|INFO', 'informativo|INFO'
    $red = 'redundancia completa|INFO', 'REDUNDANCIA PERDIDA|CRITICO', 'redundancia degradada|ATENCAO', 'sem redundancia (recursos suficientes)|ATENCAO', 'sem redundancia (vindo de perdida)|ATENCAO', 'sem redundancia (recursos insuficientes)|CRITICO', 'redundancia degradada (vindo de completa)|ATENCAO', 'redundancia degradada (vindo de perdida)|ATENCAO'

    function Decodifica([byte[]]$rec) {
        $idr = [BitConverter]::ToUInt16($rec, 0); $tr = $rec[2]
        if ($tr -ne 2) {
            $tsx = if ($tr -lt 0xE0) { [BitConverter]::ToUInt32($rec, 3) } else { 0 }
            return [pscustomobject]@{ Id = $idr; Ts = $tsx; Sensor = ('OEM (tipo 0x{0:X2})' -f $tr); SensorNum = ''; Evento = (($rec[7..15] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '); Nivel = 'INFO' }
        }
        $st = [int]$rec[10]; $sn = $rec[11]; $edt = [int]$rec[12]; $off = [int]($rec[13] -band 0x0F)
        $de = ($edt -band 0x80) -ne 0; $et = $edt -band 0x7F
        $txt = "tipo de evento 0x{0:X2} offset {1}" -f $et, $off; $niv = 'INFO'
        if ($et -eq 0x6F) { $v = $esp["$st-$off"]; if ($v) { $txt, $niv = $v.Split('|') } else { $txt = "evento especifico offset $off" } }
        elseif ($et -eq 0x01 -and $off -lt 12) { $txt = $lim[$off]; $niv = if ($off -in 0, 1, 6, 7) { 'ATENCAO' } else { 'CRITICO' } }
        elseif ($et -eq 0x07 -and $off -lt 9) { $txt, $niv = $sev[$off].Split('|') }
        elseif ($et -eq 0x0B -and $off -lt 8) { $txt, $niv = $red[$off].Split('|') }
        elseif ($et -eq 0x08) { if ($off -eq 0) { $txt = 'dispositivo removido/ausente'; $niv = 'ATENCAO' } else { $txt = 'dispositivo presente' } }
        elseif ($et -eq 0x03) { $txt = if ($off -eq 1) { 'estado ativado' } else { 'estado desativado' } }
        if ($de) { $txt = "$txt (normalizado)"; $niv = 'INFO' }
        $nomeS = $tipos[$st]; if (-not $nomeS) { $nomeS = 'sensor tipo 0x{0:X2}' -f $st }
        [pscustomobject]@{ Id = $idr; Ts = [BitConverter]::ToUInt32($rec, 3); Sensor = $nomeS; SensorNum = ('0x{0:X2}' -f $sn); Evento = $txt; Nivel = $niv }
    }

    $res = Ipmi 0x0A 0x42 @()
    $rv = if ($res -and $res.Length -ge 3 -and $res[0] -eq 0) { @($res[1], $res[2]) } else { @(0, 0) }
    $regs = New-Object System.Collections.Generic.List[object]
    $id = 0; $n = 0
    while ($n -lt 3000) {
        $r = Ipmi 0x0A 0x43 ([byte[]]@($rv[0], $rv[1], ($id -band 0xFF), (($id -shr 8) -band 0xFF), 0, 0xFF))
        if (-not ($r -and $r.Length -ge 19 -and $r[0] -eq 0)) { break }
        $prox = [BitConverter]::ToUInt16($r, 1)
        $regs.Add((Decodifica ([byte[]]$r[3..18])))
        $n++
        if ($prox -eq 0xFFFF -or $prox -eq $id) { break }
        $id = $prox
    }
    foreach ($x in $regs) {
        $h = if ($x.Ts -ge 0x20000000 -and $x.Ts -ne [uint32]::MaxValue) { $epoch.AddSeconds($x.Ts + $ajuste).ToLocalTime() } else { $null }
        $x | Add-Member -NotePropertyName Hora -NotePropertyValue $h
    }
    $regs | Select-Object Id, Hora, Sensor, SensorNum, Evento, Nivel | Export-Csv (Join-Path $outDir 'sel_bmc.csv') -NoTypeInformation -Encoding UTF8
    Write-Host "  Lidos $($regs.Count) registros (exportados em sel_bmc.csv)"
    $rel = @($regs | Where-Object { $_.Nivel -ne 'INFO' } | Sort-Object Hora -Descending)
    Sub 'SEL - eventos relevantes (ATENCAO/CRITICO), mais recentes primeiro'
    Tab ($rel | Select-Object -First 40 Hora, Sensor, SensorNum, Evento, Nivel)
    Sub 'SEL - ultimos 25 registros (todos)'
    Tab ($regs | Select-Object -Last 25 Hora, Sensor, SensorNum, Evento, Nivel)
    $lim90 = (Get-Date).AddDays(-90)
    $rel | Where-Object { $_.Hora -and $_.Hora -gt $lim90 } | Group-Object Sensor, Evento, Nivel | Sort-Object Count -Descending | Select-Object -First 12 | ForEach-Object {
        $g = $_.Group; $ultH = ($g | Sort-Object Hora -Descending)[0].Hora
        Alerta $g[0].Nivel 'Hardware (BMC)' "$($_.Count)x $($g[0].Sensor) [$($g[0].SensorNum)]: $($g[0].Evento) - ultimo em $($ultH.ToString('dd/MM/yyyy HH:mm'))"
    }
    $semData = @($rel | Where-Object { -not $_.Hora })
    if ($semData.Count) { Alerta 'INFO' 'Hardware (BMC)' "$($semData.Count) eventos de hardware relevantes sem data valida no SEL (ver tabela)" }
}


# ================================ 3. ARMAZENAMENTO ================================
Secao '3. ARMAZENAMENTO'
Rodar 'discos' {
    Sub 'Discos (visao do Windows - o array RAID aparece como um unico disco)'
    $pd = @(Get-PhysicalDisk)
    Tab ($pd | Select-Object DeviceId, FriendlyName, MediaType, BusType, HealthStatus, OperationalStatus, @{ n = 'GB'; e = { [math]::Round($_.Size / 1GB) } })
    $rc = foreach ($d in $pd) {
        $r = $d | Get-StorageReliabilityCounter
        [pscustomobject]@{ Disco = $d.FriendlyName; Temp_C = $r.Temperature; ErrosLeitura = $r.ReadErrorsTotal; LeituraNaoCorrigida = $r.ReadErrorsUncorrected; ErrosEscrita = $r.WriteErrorsTotal; EscritaNaoCorrigida = $r.WriteErrorsUncorrected; LatMaxLeitura_ms = $r.ReadLatencyMax; LatMaxEscrita_ms = $r.WriteLatencyMax; HorasLigado = $r.PowerOnHours; Desgaste = $r.Wear }
    }
    Tab $rc
    foreach ($d in $pd) {
        if ($d.HealthStatus -ne 'Healthy') { Alerta 'CRITICO' 'Armazenamento' "Disco $($d.FriendlyName): saude $($d.HealthStatus) / $($d.OperationalStatus)" }
        if ("$($d.BusType)" -eq 'USB') { Alerta 'ATENCAO' 'Armazenamento' "Disco $($d.FriendlyName) ($([math]::Round($d.Size / 1GB)) GB) ligado via USB/dock - ponto fragil para dados de producao/backup" }
        if ($d.FriendlyName -match 'ST\d+DM\d+') { Alerta 'ATENCAO' 'Armazenamento' "Disco $($d.FriendlyName) e de linha desktop (Barracuda), nao projetado para uso 24x7" }
    }
    foreach ($x in $rc) {
        if ($x.LeituraNaoCorrigida -gt 0 -or $x.EscritaNaoCorrigida -gt 0) { Alerta 'CRITICO' 'Armazenamento' "Disco $($x.Disco): erros NAO corrigidos de leitura/escrita" }
        $lm = [math]::Max([int]$x.LatMaxLeitura_ms, [int]$x.LatMaxEscrita_ms)
        if ($lm -gt 1000) { Alerta 'ATENCAO' 'Armazenamento' "Disco $($x.Disco): latencia maxima registrada de $lm ms" }
    }
    Sub 'Controladora de disco'
    Tab (Get-CimInstance Win32_SCSIController | Select-Object Name, DriverName, Status)
    Alerta 'INFO' 'Armazenamento' 'Nivel de RAID, cache e saude individual dos discos do array C:/D: nao sao visiveis pelo Windows - verificar pela controladora (Ctrl+R no boot) ou TSM'

    Sub 'Volumes'
    $vols = @(Get-Volume | Where-Object { $_.DriveLetter } | Sort-Object DriveLetter)
    Tab ($vols | Select-Object DriveLetter, FileSystemLabel, FileSystem, DriveType, HealthStatus, @{ n = 'TotalGB'; e = { [math]::Round($_.Size / 1GB, 1) } }, @{ n = 'LivreGB'; e = { [math]::Round($_.SizeRemaining / 1GB, 1) } }, @{ n = 'Livre%'; e = { if ($_.Size) { [math]::Round(100 * $_.SizeRemaining / $_.Size, 1) } } })
    foreach ($v in $vols | Where-Object { $_.Size -gt 1GB }) {
        $L = "$($v.DriveLetter):"
        $pct = 100 * $v.SizeRemaining / $v.Size
        if ($pct -lt 10) { Alerta 'CRITICO' 'Armazenamento' ("Volume {0} com apenas {1:N1}% livre ({2:N0} GB)" -f $L, $pct, ($v.SizeRemaining / 1GB)) }
        elseif ($pct -lt 15) { Alerta 'ATENCAO' 'Armazenamento' ("Volume {0} com {1:N1}% livre ({2:N0} GB)" -f $L, $pct, ($v.SizeRemaining / 1GB)) }
        if ($v.HealthStatus -ne 'Healthy') { Alerta 'CRITICO' 'Armazenamento' "Volume $L com saude $($v.HealthStatus)" }
        if ($v.FileSystem -eq 'NTFS') {
            $dq = "$(fsutil dirty query $L)"
            Write-Host "  $dq"
            if ($dq -match 'is Dirty') { Alerta 'CRITICO' 'Armazenamento' "Volume $L marcado como 'dirty' - o Windows detectou inconsistencia (precisa chkdsk)" }
        }
    }

    Sub 'Eventos de disco / controladora / NTFS - 30 dias'
    $de = @(Ev System @(7, 9, 11, 15, 50, 51, 52, 55, 57, 98, 129, 140, 153, 154, 157) 30 | Where-Object {
            $_.ProviderName -match 'disk|ntfs|stor|megasas|megasr|lsi|percsas|volmgr|iaStor|partmgr|classpnp|Kernel-IO' -and -not ($_.Id -eq 98 -and $_.Message -match 'is healthy|No action is needed') })
    Tab ($de | Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object Count, Name, @{ n = 'Ultimo'; e = { ($_.Group | Sort-Object TimeCreated -Descending)[0].TimeCreated } }, @{ n = 'Exemplo'; e = { Msg1 $_.Group[0] 120 } })
    $graves = @($de | Where-Object { $_.Id -in 7, 11, 15, 51, 129, 153, 154, 157 -or ($_.Id -in 55, 98, 140 -and $_.ProviderName -match 'Ntfs') })
    if ($graves.Count) { Alerta 'CRITICO' 'Armazenamento' "$($graves.Count) eventos de erro de disco/controladora/NTFS em 30 dias (ver tabela)" }

    Sub 'Arquivo de paginacao e despejo de memoria'
    Write-Host "  Pagefile gerenciado automaticamente: $((Get-CimInstance Win32_ComputerSystem).AutomaticManagedPagefile)"
    Tab (Get-CimInstance Win32_PageFileUsage | Select-Object Name, AllocatedBaseSize, CurrentUsage, PeakUsage)
    $cc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
    Write-Host ("  CrashDumpEnabled={0} (0=nenhum 1=completo 2=kernel 3=mini 7=automatico)  DumpFile={1}  AutoReboot={2}  DedicatedDumpFile={3}" -f $cc.CrashDumpEnabled, $cc.DumpFile, $cc.AutoReboot, $cc.DedicatedDumpFile)
}

if (-not $PularTamanhos) {
    Rodar 'ocupacao' {
        Sub 'Ocupacao por pasta (C:\ sem a pasta Windows, D:\ e G:\) - pode levar alguns minutos'
        foreach ($raiz in 'C:\', 'D:\', 'G:\') {
            if (-not (Test-Path $raiz)) { continue }
            $ps = @(Get-ChildItem $raiz -Directory -Force | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $_.Name -notin 'Windows', 'System Volume Information', '$Recycle.Bin', 'Recovery', 'Config.Msi' })
            Write-Host "  Medindo $raiz ($($ps.Count) pastas)..." -ForegroundColor DarkGray
            $tam = foreach ($p in $ps) { TamanhoPasta $p.FullName }
            Tab ($tam | Sort-Object GB -Descending | Select-Object -First 15)
            $soltos = Get-ChildItem $raiz -File -Force | Where-Object { $_.Length -gt 1GB }
            if ($soltos) { Write-Host "  Arquivos grandes na raiz de $($raiz)"; Tab ($soltos | Select-Object Name, @{ n = 'GB'; e = { [math]::Round($_.Length / 1GB, 1) } }, LastWriteTime) }
        }
    }
}

# ================================ 4. DESEMPENHO ================================
Secao '4. DESEMPENHO (amostra de 2 minutos)'
Rodar 'desempenho' {
    $cont = '\Processor(_Total)\% Processor Time', '\System\Processor Queue Length', '\Memory\Available MBytes', '\Memory\Pages/sec', '\Memory\Committed Bytes', '\Memory\Pool Nonpaged Bytes',
            '\LogicalDisk(*)\Avg. Disk sec/Read', '\LogicalDisk(*)\Avg. Disk sec/Write', '\LogicalDisk(*)\Disk Reads/sec', '\LogicalDisk(*)\Disk Writes/sec', '\LogicalDisk(*)\Current Disk Queue Length', '\Network Interface(*)\Bytes Total/sec'
    $sqlc = @(Get-Counter -ListSet '*Buffer Manager*', '*General Statistics*', '*SQL Statistics*', '*Memory Manager*' | ForEach-Object { $_.Paths } | Where-Object { $_ -match 'Page life expectancy|Batch Requests/sec|User Connections|Total Server Memory|Target Server Memory|Page reads/sec|Lazy writes/sec' })
    $am = Get-Counter -Counter (@($cont) + $sqlc) -SampleInterval 5 -MaxSamples 24
    $stats = $am.CounterSamples | Group-Object Path | ForEach-Object {
        $v = $_.Group.CookedValue
        [pscustomobject]@{ Contador = ($_.Name -replace '^\\\\[^\\]+\\', ''); Media = [math]::Round(($v | Measure-Object -Average).Average, 3); Max = [math]::Round(($v | Measure-Object -Maximum).Maximum, 3) }
    }
    Tab ($stats | Where-Object { $_.Contador -notmatch '_total|harddiskvolume|isatap|teredo' -and ($_.Media -ne 0 -or $_.Max -ne 0) } | Sort-Object Contador)
    foreach ($s in $stats) {
        if ($s.Contador -notmatch 'logicaldisk\(([a-z]:)\)\\avg\. disk sec/(read|write)') { continue }
        $vol = $matches[1].ToUpper(); $op = if ($matches[2] -eq 'read') { 'leitura' } else { 'escrita' }
        $ms = [math]::Round($s.Media * 1000); $mx = [math]::Round($s.Max * 1000)
        if ($ms -gt 50) { Alerta 'CRITICO' 'Desempenho' "Latencia media de $op em $vol = $ms ms (max $mx ms) - ideal < 20 ms" }
        elseif ($ms -gt 20) { Alerta 'ATENCAO' 'Desempenho' "Latencia media de $op em $vol = $ms ms (max $mx ms) - ideal < 20 ms" }
    }
    $cpu = $stats | Where-Object { $_.Contador -match 'processor\(_total\)' } | Select-Object -First 1
    if ($cpu -and $cpu.Media -gt 80) { Alerta 'ATENCAO' 'Desempenho' "CPU media de $([math]::Round($cpu.Media))% na amostra" }
    $ple = $stats | Where-Object { $_.Contador -match 'page life expectancy' } | Select-Object -First 1
    if ($ple -and $ple.Media -lt 300) { Alerta 'ATENCAO' 'SQL Server' "Page Life Expectancy baixo ($([math]::Round($ple.Media)) s) - pouca memoria de cache para o volume de dados" }

    Sub 'Processos - maior uso de memoria'
    Tab (Get-Process | Sort-Object WS -Descending | Select-Object -First 15 Name, Id, @{ n = 'RAM_MB'; e = { [math]::Round($_.WS / 1MB) } }, @{ n = 'Privada_MB'; e = { [math]::Round($_.PrivateMemorySize64 / 1MB) } }, Handles, @{ n = 'Threads'; e = { $_.Threads.Count } }, @{ n = 'CPU_s'; e = { [math]::Round($_.CPU) } }, StartTime)
    Sub 'Processos - mais handles'
    $hd = Get-Process | Sort-Object Handles -Descending | Select-Object -First 8 Name, Id, Handles
    Tab $hd
    foreach ($h in $hd | Where-Object { $_.Handles -gt 30000 }) { Alerta 'ATENCAO' 'Desempenho' "Processo $($h.Name) com $($h.Handles) handles (possivel vazamento)" }
    Sub 'Processos - uso de CPU agora (amostra de 10 s)'
    $p1 = @{}; Get-Process | ForEach-Object { $p1[$_.Id] = $_.CPU }
    Start-Sleep -Seconds 10
    $nc = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    Tab (Get-Process | ForEach-Object { if ($p1.ContainsKey($_.Id) -and $_.CPU) { [pscustomobject]@{ Nome = $_.Name; Id = $_.Id; 'CPU%' = [math]::Round(100 * ($_.CPU - $p1[$_.Id]) / 10 / $nc, 1) } } } | Sort-Object 'CPU%' -Descending | Select-Object -First 10)
}


# ================================ 5. SQL SERVER ================================
Secao '5. SQL SERVER'
Rodar 'sql' {
    $inst = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').MSSQLSERVER
    if (-not $inst) { Write-Host '  Instancia padrao (MSSQLSERVER) nao encontrada'; return }
    $base  = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$inst"
    $setup = Get-ItemProperty "$base\Setup"
    $cfg   = Get-ItemProperty "$base\MSSQLServer"
    $sqlArgs = (Get-ItemProperty "$base\MSSQLServer\Parameters").PSObject.Properties | Where-Object { $_.Name -like 'SQLArg*' } | ForEach-Object { $_.Value }
    $errLog = "$($sqlArgs | Where-Object { $_ -like '-e*' })" -replace '^-e', ''
    $master = "$($sqlArgs | Where-Object { $_ -like '-d*' })" -replace '^-d', ''
    $verStr = @($setup.PatchLevel, $setup.Version) | Where-Object { $_ } | Select-Object -First 1
    $maj = [int]("$verStr".Split('.')[0])
    $nome = @{ 11 = '2012'; 12 = '2014'; 13 = '2016'; 14 = '2017'; 15 = '2019'; 16 = '2022'; 17 = '2025' }[$maj]
    $fim  = @{ 11 = '2022-07-12'; 12 = '2024-07-09'; 13 = '2026-07-14'; 14 = '2027-10-12'; 15 = '2030-01-08'; 16 = '2033-01-11' }[$maj]
    Lst ([pscustomobject]@{ Instancia = $inst; Versao = "SQL Server $nome (build $verStr)"; Edicao = $setup.Edition; PastaDadosPadrao = $cfg.DefaultData; PastaLogPadrao = $cfg.DefaultLog; PastaBackupPadrao = $cfg.BackupDirectory; Master = $master; ErrorLog = $errLog })
    if ($fim) {
        $d = ([datetime]$fim - (Get-Date)).Days
        $fimTxt = ([datetime]$fim).ToString('dd/MM/yyyy')
        if ($d -lt 0) { Alerta 'CRITICO' 'SQL Server' "SQL Server $($nome) FORA DO SUPORTE da Microsoft desde $fimTxt - sem correcoes de seguranca" }
        elseif ($d -lt 365) { Alerta 'ATENCAO' 'SQL Server' "SQL Server $($nome) - suporte termina em $fimTxt ($d dias)" }
    }
    if ($setup.Edition -match 'Express') { Alerta 'ATENCAO' 'SQL Server' 'Edicao Express: limite de 10 GB por banco e pouca memoria' }

    Sub 'Servicos do SQL'
    Tab (Get-Service MSSQLSERVER, SQLSERVERAGENT, SQLBrowser, SQLWriter, MSSQLFDLauncher | Select-Object Name, Status, StartType)
    if ((Get-Service SQLSERVERAGENT).Status -ne 'Running') { Alerta 'ATENCAO' 'SQL Server' 'SQL Server Agent parado - jobs agendados do SQL (backup/manutencao) nao executam' }

    Sub 'Arquivos de banco de dados (pastas padrao)'
    $dirs = @($cfg.DefaultData, $cfg.DefaultLog, $(if ($master) { Split-Path $master }), $(if ($setup.SQLDataRoot) { Join-Path $setup.SQLDataRoot 'DATA' })) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
    $arqs = @(foreach ($dd in $dirs) { Get-ChildItem $dd -File -Force | Where-Object { $_.Extension -in '.mdf', '.ndf', '.ldf' } }) | Sort-Object FullName -Unique | Sort-Object Length -Descending
    Tab ($arqs | Select-Object Name, DirectoryName, @{ n = 'GB'; e = { [math]::Round($_.Length / 1GB, 1) } }, LastWriteTime)
    foreach ($a in $arqs | Where-Object { $_.Extension -eq '.ldf' -and $_.Length -gt 20GB }) { Alerta 'ATENCAO' 'SQL Server' "Log de transacao grande: $($a.Name) com $([math]::Round($a.Length / 1GB)) GB (possivel falta de backup de log)" }
    if ($arqs | Where-Object { $_.FullName -like 'C:\*' -and $_.Length -gt 1GB }) { Alerta 'ATENCAO' 'SQL Server' 'Ha arquivos de banco maiores que 1 GB no disco do sistema (C:)' }

    Sub 'ERRORLOG do SQL Server'
    if (-not $errLog -or -not (Test-Path (Split-Path $errLog))) { Write-Host '  ERRORLOG nao encontrado'; return }
    $fs = @(Get-ChildItem (Split-Path $errLog) -File | Where-Object { $_.Name -match '^ERRORLOG(\.\d+)?$' } | Sort-Object LastWriteTime -Descending | Select-Object -First 7)
    Tab ($fs | Select-Object Name, LastWriteTime, @{ n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } })
    $fsLer = @($fs | Where-Object { $_.Length -lt 300MB } | ForEach-Object { $_.FullName })
    if (-not $fsLer.Count) { return }
    $desde = DataLinha "$(Get-Content $fsLer[-1] -TotalCount 1)"
    Write-Host "  Periodo coberto pelos logs: desde $desde"
    $pad = 'taking longer than 15 seconds', 'Error: \d+, Severity: (1[7-9]|2\d)', 'paged out', 'Non-yielding|non-yielding', 'deadlock', 'Login failed', 'backed up\. Database:', 'DBCC CHECKDB \(', 'Autogrow of file', 'Stack Signature|stack dump|Access Violation|EXCEPTION_', 'log for database .* is full', 'Could not allocate', 'SQL Server is starting'
    $hits = @(Select-String -Path $fsLer -Pattern $pad)
    $cats = [ordered]@{ 'I/O acima de 15 s (aviso 833)' = 'taking longer than 15 seconds'; 'Erros severidade >= 17' = 'Severity: (1[7-9]|2\d)'; 'Memoria do SQL paginada' = 'paged out'; 'Scheduler travado (non-yielding)' = '[Nn]on-yielding'; 'Deadlocks' = 'deadlock'; 'Login falhou' = 'Login failed'; 'Crescimento automatico de arquivo' = 'Autogrow of file'; 'Dump/excecao' = 'Stack Signature|stack dump|Access Violation|EXCEPTION_'; 'Log de transacao cheio' = 'log for database .* is full'; 'Sem espaco no arquivo' = 'Could not allocate'; 'Inicializacoes do SQL' = 'SQL Server is starting' }
    $resumo = foreach ($k in $cats.Keys) { $m = @($hits | Where-Object { $_.Line -match $cats[$k] }); [pscustomobject]@{ Tipo = $k; Ocorrencias = $m.Count; Ultima = ($m | ForEach-Object { DataLinha $_.Line } | Sort-Object | Select-Object -Last 1) } }
    Tab $resumo
    $q = @{}; foreach ($x in $resumo) { $q[$x.Tipo] = $x.Ocorrencias }
    $io = @($hits | Where-Object { $_.Line -match 'taking longer than 15 seconds' })
    if ($io.Count) {
        Write-Host '  Exemplos de I/O lento:'
        $io | Select-Object -Last 3 | ForEach-Object { Write-Host "    $($_.Line.Substring(0, [Math]::Min(320, $_.Line.Length)))" }
        Alerta 'CRITICO' 'SQL Server' "$($io.Count) avisos de I/O acima de 15 segundos no SQL desde $desde (o disco nao acompanha a carga)"
    }
    $sv = @($hits | Where-Object { $_.Line -match 'Severity: (1[7-9]|2\d)' })
    if ($sv.Count) {
        Tab ($sv | Group-Object { if ($_.Line -match 'Error: (\d+), Severity: (\d+)') { "Erro $($matches[1]) severidade $($matches[2])" } } | Sort-Object Count -Descending | Select-Object Count, Name)
        Alerta 'ATENCAO' 'SQL Server' "$($sv.Count) erros de severidade >= 17 no ERRORLOG (ver tabela)"
    }
    if ($q['Memoria do SQL paginada']) { Alerta 'ATENCAO' 'SQL Server' 'O Windows paginou memoria do SQL para o disco (avaliar Lock Pages in Memory / max server memory)' }
    if ($q['Scheduler travado (non-yielding)']) { Alerta 'CRITICO' 'SQL Server' 'SQL registrou scheduler travado (non-yielding) - congelamento interno do SQL' }
    if ($q['Dump/excecao']) { Alerta 'CRITICO' 'SQL Server' 'SQL gerou dump/excecao (ver ERRORLOG)' }
    if ($q['Log de transacao cheio']) { Alerta 'CRITICO' 'SQL Server' 'Log de transacao ficou CHEIO (parada de gravacao no banco)' }
    if ($q['Sem espaco no arquivo']) { Alerta 'CRITICO' 'SQL Server' 'SQL ficou sem espaco para alocar dados (Could not allocate)' }
    if ($q['Inicializacoes do SQL'] -gt 3) { Alerta 'INFO' 'SQL Server' "SQL iniciou $($q['Inicializacoes do SQL']) vezes no periodo dos logs (cada inicio zera o cache)" }
    $lf = @($hits | Where-Object { $_.Line -match 'Login failed for user' })
    if ($lf.Count) { Tab ($lf | Group-Object { if ($_.Line -match "Login failed for user '([^']*)'") { $matches[1] } } | Sort-Object Count -Descending | Select-Object -First 10 Count, @{ n = 'Login'; e = { $_.Name } }) }

    Sub 'Backups e CHECKDB registrados no ERRORLOG'
    $bk = foreach ($h in $hits) {
        if ($h.Line -match '(Database|Log was) backed up\. Database: ([^,]+),') {
            $tipo = if ($matches[1] -eq 'Log was') { 'LOG' } else { 'FULL/DIFF' }; $bn = $matches[2].Trim()
            [pscustomobject]@{ Tipo = $tipo; Banco = $bn; Data = (DataLinha $h.Line) }
        }
    }
    if ($bk) { Tab ($bk | Group-Object Banco, Tipo | ForEach-Object { [pscustomobject]@{ Banco = $_.Group[0].Banco; Tipo = $_.Group[0].Tipo; Quantidade = $_.Count; Ultimo = ($_.Group.Data | Sort-Object | Select-Object -Last 1) } } | Sort-Object Banco) }
    else { Alerta 'ATENCAO' 'SQL Server' "Nenhum backup nativo do SQL registrado no ERRORLOG desde $desde - confirmar como o banco e copiado" }
    $ck = foreach ($h in $hits) {
        if ($h.Line -match 'DBCC CHECKDB \((.+?)\).*found (\d+) errors') { $bn = $matches[1]; $er = [int]$matches[2]; [pscustomobject]@{ Banco = $bn; Erros = $er; Data = (DataLinha $h.Line) } }
    }
    if ($ck) {
        Tab ($ck | Group-Object Banco | ForEach-Object { $_.Group | Sort-Object Data | Select-Object -Last 1 })
        foreach ($x in $ck | Where-Object { $_.Erros -gt 0 }) { Alerta 'CRITICO' 'SQL Server' "DBCC CHECKDB encontrou $($x.Erros) erros de CORRUPCAO no banco $($x.Banco) ($($x.Data))" }
    } else { Alerta 'ATENCAO' 'SQL Server' "Nenhum DBCC CHECKDB registrado desde $desde - integridade dos bancos possivelmente nao verificada" }
}


Rodar 'sql-consultas' {
    Sub 'Consultas internas do SQL (somente SELECT)'
    $exe = (Get-Command sqlcmd.exe -ErrorAction SilentlyContinue).Source
    if (-not $exe) { Write-Host '  sqlcmd nao encontrado'; return }
    if ($SqlUser) {
        $sec = Read-Host "  Senha do login SQL '$SqlUser' (nao aparece na tela)" -AsSecureString
        $env:SQLCMDPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
        $auth = @('-U', $SqlUser)
    } else { $auth = @('-E') }
    try {
        function Q([string]$Titulo, [string]$Sql) {
            Write-Host "`n  >> $Titulo" -ForegroundColor DarkCyan
            & $exe -S . @auth -l 15 -t 300 -W -s ' | ' -Q ('SET NOCOUNT ON; ' + ($Sql -replace '\s+', ' ')) 2>&1 | Out-String -Width 400 | Write-Host
        }
        function QL([string]$Sql) {
            & $exe -S . @auth -l 15 -t 300 -h -1 -W -s '|' -Q ('SET NOCOUNT ON; ' + ($Sql -replace '\s+', ' ')) 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ }
        }
        $t = "$(QL "SELECT CAST(IS_SRVROLEMEMBER('sysadmin') AS varchar(5)) + '|' + CAST(HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE') AS varchar(5))")"
        if ($t -notmatch '^\d\|\d$') {
            Write-Host "  Sem acesso ao SQL: $t" -ForegroundColor Yellow
            Alerta 'INFO' 'SQL Server' 'Consultas internas do SQL nao executadas (sem login com permissao) - rodar de novo com -SqlUser'
            return
        }
        Write-Host "  Acesso (sysadmin|VIEW SERVER STATE): $t"
        $inv = [Globalization.CultureInfo]::InvariantCulture

        Q 'Versao' 'SELECT @@VERSION'
        Q 'Configuracoes principais' "SELECT name, value_in_use FROM sys.configurations WHERE name IN ('max server memory (MB)','min server memory (MB)','max degree of parallelism','cost threshold for parallelism','optimize for ad hoc workloads','backup compression default')"
        Q 'Inicio do SQL e CPUs' 'SELECT sqlserver_start_time, cpu_count, scheduler_count, physical_memory_kb/1024 AS ram_mb FROM sys.dm_os_sys_info'
        Q 'Memoria do processo SQL' 'SELECT physical_memory_in_use_kb/1024 AS em_uso_mb, locked_page_allocations_kb/1024 AS locked_pages_mb, memory_utilization_percentage AS pct, process_physical_memory_low AS mem_baixa FROM sys.dm_os_process_memory'
        Q 'Bancos' "SELECT d.name, d.state_desc, d.recovery_model_desc AS recovery, d.log_reuse_wait_desc AS log_aguarda, d.compatibility_level AS compat, d.page_verify_option_desc AS page_verify,
            CAST(SUM(CASE WHEN f.type=0 THEN f.size END)/128.0/1024 AS decimal(10,1)) AS dados_gb, CAST(SUM(CASE WHEN f.type=1 THEN f.size END)/128.0/1024 AS decimal(10,1)) AS log_gb
            FROM sys.databases d JOIN sys.master_files f ON f.database_id=d.database_id
            GROUP BY d.name, d.state_desc, d.recovery_model_desc, d.log_reuse_wait_desc, d.compatibility_level, d.page_verify_option_desc ORDER BY dados_gb DESC"
        Q 'Uso do log de transacao' 'DBCC SQLPERF(LOGSPACE)'
        Q 'Ultimos backups (msdb)' "SELECT d.name, MAX(CASE WHEN b.type='D' THEN b.backup_finish_date END) AS ultimo_full, MAX(CASE WHEN b.type='I' THEN b.backup_finish_date END) AS ultimo_diff, MAX(CASE WHEN b.type='L' THEN b.backup_finish_date END) AS ultimo_log
            FROM sys.databases d LEFT JOIN msdb.dbo.backupset b ON b.database_name=d.name WHERE d.name<>'tempdb' GROUP BY d.name ORDER BY d.name"
        Q 'Destino dos 10 ultimos backups' 'SELECT TOP 10 b.database_name, b.type, b.backup_finish_date, CAST(b.backup_size/1073741824.0 AS decimal(10,1)) AS gb, b.is_copy_only, m.physical_device_name FROM msdb.dbo.backupset b JOIN msdb.dbo.backupmediafamily m ON m.media_set_id=b.media_set_id ORDER BY b.backup_finish_date DESC'
        Q 'Paginas suspeitas de corrupcao' 'SELECT * FROM msdb.dbo.suspect_pages'
        Q 'Latencia por arquivo desde o ultimo inicio do SQL' "SELECT DB_NAME(v.database_id) AS db, f.type_desc, f.physical_name, v.num_of_reads AS leituras, CAST(v.io_stall_read_ms*1.0/NULLIF(v.num_of_reads,0) AS decimal(10,1)) AS ms_leitura,
            v.num_of_writes AS escritas, CAST(v.io_stall_write_ms*1.0/NULLIF(v.num_of_writes,0) AS decimal(10,1)) AS ms_escrita
            FROM sys.dm_io_virtual_file_stats(NULL,NULL) v JOIN sys.master_files f ON f.database_id=v.database_id AND f.file_id=v.file_id ORDER BY v.io_stall_read_ms+v.io_stall_write_ms DESC"
        Q 'Principais esperas (desde o inicio do SQL)' "SELECT TOP 12 wait_type, CAST(wait_time_ms/60000.0 AS decimal(12,1)) AS minutos, waiting_tasks_count AS qtd, CAST(100.0*wait_time_ms/SUM(wait_time_ms) OVER() AS decimal(5,1)) AS pct
            FROM sys.dm_os_wait_stats WHERE wait_time_ms > 0 AND wait_type NOT LIKE 'SLEEP%' AND wait_type NOT LIKE 'BROKER%' AND wait_type NOT LIKE 'XE%' AND wait_type NOT LIKE 'QDS%' AND wait_type NOT LIKE 'HADR%' AND wait_type NOT LIKE 'PARALLEL_REDO%'
            AND wait_type NOT IN ('SQLTRACE_BUFFER_FLUSH','CLR_AUTO_EVENT','CLR_MANUAL_EVENT','LAZYWRITER_SLEEP','CHECKPOINT_QUEUE','REQUEST_FOR_DEADLOCK_SEARCH','LOGMGR_QUEUE','DIRTY_PAGE_POLL','SP_SERVER_DIAGNOSTICS_SLEEP','WAITFOR','ONDEMAND_TASK_QUEUE','FT_IFTSHC_MUTEX','KSOURCE_WAKEUP','SNI_HTTP_ACCEPT','PWAIT_ALL_COMPONENTS_INITIALIZED','WAIT_XTP_OFFLINE_CKPT_NEW_LOG','PREEMPTIVE_OS_FLUSHFILEBUFFERS')
            ORDER BY wait_time_ms DESC"
        Q 'Crescimento automatico dos arquivos' "SELECT DB_NAME(database_id) AS db, name, type_desc, size/128 AS mb, CASE WHEN is_percent_growth=1 THEN CAST(growth AS varchar(10))+'%' ELSE CAST(growth/128 AS varchar(10))+' MB' END AS crescimento,
            CASE max_size WHEN -1 THEN 'ilimitado' WHEN 0 THEN 'sem crescimento' ELSE CAST(max_size/128 AS varchar(12))+' MB' END AS limite, physical_name FROM sys.master_files ORDER BY size DESC"
        Q 'TempDB - arquivos de dados' 'SELECT name, size/128 AS mb, physical_name FROM tempdb.sys.database_files'
        Q 'Jobs do SQL Agent' "SELECT j.name, j.enabled, CASE x.run_status WHEN 0 THEN 'FALHOU' WHEN 1 THEN 'OK' WHEN 2 THEN 'Retry' WHEN 3 THEN 'Cancelado' ELSE '-' END AS ultimo_status, msdb.dbo.agent_datetime(x.run_date, x.run_time) AS ultima_exec
            FROM msdb.dbo.sysjobs j OUTER APPLY (SELECT TOP 1 run_status, run_date, run_time FROM msdb.dbo.sysjobhistory h WHERE h.job_id=j.job_id AND h.step_id=0 ORDER BY run_date DESC, run_time DESC) x ORDER BY j.name"
        Q 'Conexoes por aplicacao' 'SELECT program_name, login_name, COUNT(*) AS sessoes FROM sys.dm_exec_sessions WHERE is_user_process=1 GROUP BY program_name, login_name ORDER BY sessoes DESC'

        # ---- alertas automaticos ----
        foreach ($l in (QL "SELECT d.name + '|' + ISNULL(CAST(DATEDIFF(hour, MAX(b.backup_finish_date), GETDATE()) AS varchar(10)), '-1') FROM sys.databases d LEFT JOIN msdb.dbo.backupset b ON b.database_name=d.name AND b.type='D' WHERE d.database_id > 4 AND d.state = 0 GROUP BY d.name")) {
            $p = $l.Split('|'); if ($p.Count -lt 2) { continue }
            $h = [int]$p[1]
            if ($h -lt 0) { Alerta 'CRITICO' 'SQL Server' "Banco $($p[0]): NENHUM backup full registrado pelo SQL" }
            elseif ($h -gt 48) { Alerta 'CRITICO' 'SQL Server' "Banco $($p[0]): ultimo backup full ha $h horas" }
            elseif ($h -gt 26) { Alerta 'ATENCAO' 'SQL Server' "Banco $($p[0]): ultimo backup full ha $h horas" }
        }
        foreach ($l in (QL "SELECT d.name FROM sys.databases d WHERE d.recovery_model=1 AND d.database_id > 4 AND NOT EXISTS (SELECT 1 FROM msdb.dbo.backupset b WHERE b.database_name=d.name AND b.type='L' AND b.backup_finish_date > DATEADD(day,-1,GETDATE()))")) {
            Alerta 'ATENCAO' 'SQL Server' "Banco $l em recovery FULL sem backup de log nas ultimas 24h (o log cresce e a restauracao fica limitada ao ultimo full)"
        }
        $sp = "$(QL 'SELECT COUNT(*) FROM msdb.dbo.suspect_pages')"
        if ($sp -match '^\d+$' -and [int]$sp -gt 0) { Alerta 'CRITICO' 'SQL Server' "$sp pagina(s) suspeita(s) de corrupcao em msdb.dbo.suspect_pages" }
        $mm = "$(QL "SELECT CAST(value_in_use AS bigint) FROM sys.configurations WHERE name='max server memory (MB)'")"
        if ($mm -eq '2147483647') { Alerta 'ATENCAO' 'SQL Server' 'max server memory no padrao (ilimitado) - SQL pode disputar RAM com o Windows e o Protheus' }
        $ckl = @(QL "SELECT name + '|' + ISNULL(CONVERT(varchar(19), CAST(DATABASEPROPERTYEX(name,'LastGoodCheckDbTime') AS datetime), 120), '') FROM sys.databases WHERE database_id <> 2 AND state = 0")
        $ckOk = @($ckl | Where-Object { $_ -match '\|\d{4}-' })
        if ($ckOk.Count) {
            foreach ($l in $ckOk) {
                $p = $l.Split('|'); $dt = [datetime]::ParseExact($p[1], 'yyyy-MM-dd HH:mm:ss', $inv)
                if ($dt.Year -lt 2000) { Alerta 'ATENCAO' 'SQL Server' "Banco $($p[0]): DBCC CHECKDB nunca concluido com sucesso" }
                elseif (((Get-Date) - $dt).Days -gt 30) { Alerta 'ATENCAO' 'SQL Server' "Banco $($p[0]): ultimo CHECKDB sem erros ha $(((Get-Date) - $dt).Days) dias" }
            }
        }
        foreach ($l in (QL 'SELECT j.name FROM msdb.dbo.sysjobs j CROSS APPLY (SELECT TOP 1 run_status FROM msdb.dbo.sysjobhistory h WHERE h.job_id=j.job_id AND h.step_id=0 ORDER BY run_date DESC, run_time DESC) x WHERE j.enabled=1 AND x.run_status=0')) {
            Alerta 'ATENCAO' 'SQL Server' "Job do SQL Agent falhou na ultima execucao: $l"
        }
        foreach ($l in (QL "SELECT DB_NAME(v.database_id) + ' (' + f.type_desc + ')|' + CAST(CAST(v.io_stall_read_ms*1.0/NULLIF(v.num_of_reads,0) AS decimal(10,1)) AS varchar(20)) + '|' + ISNULL(CAST(CAST(v.io_stall_write_ms*1.0/NULLIF(v.num_of_writes,0) AS decimal(10,1)) AS varchar(20)),'0') FROM sys.dm_io_virtual_file_stats(NULL,NULL) v JOIN sys.master_files f ON f.database_id=v.database_id AND f.file_id=v.file_id WHERE v.num_of_reads > 1000")) {
            $p = $l.Split('|'); if ($p.Count -lt 3) { continue }
            $r = [double]::Parse($p[1], $inv); $w = [double]::Parse($p[2], $inv)
            if ($r -gt 50 -or $w -gt 50) { Alerta 'CRITICO' 'SQL Server' "Arquivo $($p[0]): latencia media leitura $r ms / escrita $w ms (ideal < 20 ms)" }
            elseif ($r -gt 20 -or $w -gt 20) { Alerta 'ATENCAO' 'SQL Server' "Arquivo $($p[0]): latencia media leitura $r ms / escrita $w ms (ideal < 20 ms)" }
        }
    } finally { Remove-Item Env:\SQLCMDPASSWORD -ErrorAction SilentlyContinue }
}


# ================================ 6. SERVICOS ================================
Secao '6. SERVICOS'
$script:TotvsRx = 'APPSERVER|DBACCESS|TOTVS|LICENSE|TReports|SmartClient|Protheus'
Rodar 'servicos' {
    $svc = @(Get-CimInstance Win32_Service)
    $normais = 'gupdate', 'gupdatem', 'edgeupdate', 'edgeupdatem', 'GoogleUpdater', 'RemoteRegistry', 'sppsvc', 'MapsBroker', 'tiledatamodelsvc', 'CDPSvc', 'CDPUserSvc', 'OneSyncSvc', 'WbioSrvc', 'TrustedInstaller', 'ShellHWDetection', 'wuauserv', 'BITS', 'UsoSvc', 'DoSvc', 'stisvc', 'WSearch', 'clr_optimization', 'sppuinotify', 'TabletInputService', 'dmwappushservice', 'AppReadiness', 'WinDefend', 'WdNisSvc', 'Sense'
    Sub 'Servicos automaticos que NAO estao rodando'
    $par = foreach ($s in $svc | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' }) {
        $ok = [bool]($normais | Where-Object { $s.Name -like "$_*" })
        $av = if ($ok) { 'normal (inicia sob demanda)' } elseif ($s.Name -match $script:TotvsRx -or $s.PathName -match $script:TotvsRx) { 'TOTVS - informativo' } else { 'VERIFICAR' }
        [pscustomobject]@{ Servico = $s.Name; Nome = $s.DisplayName; Estado = $s.State; Atrasado = $s.DelayedAutoStart; Avaliacao = $av }
    }
    Tab $par
    foreach ($x in $par | Where-Object { $_.Avaliacao -eq 'VERIFICAR' }) { Alerta 'ATENCAO' 'Servicos' "Servico automatico parado: $($x.Servico) ($($x.Nome))" }
    foreach ($x in $par | Where-Object { $_.Avaliacao -like 'TOTVS*' }) { Alerta 'INFO' 'Servicos' "Servico TOTVS automatico parado (repassar ao responsavel): $($x.Servico)" }

    Sub 'Servicos que cairam sozinhos (7031/7034) - 30 dias'
    $g = @(Ev System @(7031, 7034) 30 | Group-Object { $_.Properties[0].Value } | Sort-Object Count -Descending)
    Tab ($g | Select-Object Count, @{ n = 'Servico'; e = { $_.Name } }, @{ n = 'Ultima'; e = { ($_.Group | Sort-Object TimeCreated -Descending)[0].TimeCreated } })
    foreach ($x in $g) {
        $tot = if ($x.Name -match $script:TotvsRx) { ' (TOTVS - repassar ao suporte TOTVS)' } else { '' }
        Alerta 'ATENCAO' 'Servicos' "Servico '$($x.Name)' caiu sozinho $($x.Count)x em 30 dias$tot"
    }

    Sub 'Servicos com executavel inexistente ou caminho sem aspas'
    $cam = foreach ($s in $svc) {
        $p = "$($s.PathName)".Trim(); if (-not $p) { continue }
        $m = [regex]::Match($p, '^"?(?:\\\?\?\\)?([^"]+?\.(?:exe|com|bat|cmd))', 'IgnoreCase')
        if (-not $m.Success) { continue }
        $exe = [Environment]::ExpandEnvironmentVariables($m.Groups[1].Value)
        $falta = -not (Test-Path -LiteralPath $exe)
        $semAspas = (-not $p.StartsWith('"')) -and ($exe -match ' ')
        if ($falta -or $semAspas) { [pscustomobject]@{ Servico = $s.Name; Executavel = $exe; NaoExiste = $falta; SemAspas = $semAspas; Inicio = $s.StartMode } }
    }
    Tab $cam
    foreach ($x in $cam) {
        if ($x.NaoExiste -and $x.Inicio -ne 'Disabled') { Alerta 'INFO' 'Servicos' "Servico '$($x.Servico)' aponta para executavel inexistente (sobra de instalacao antiga)" }
        if ($x.SemAspas) { Alerta 'ATENCAO' 'Seguranca' "Servico '$($x.Servico)' com caminho com espacos e sem aspas (falha conhecida de escalonamento de privilegio)" }
    }

    Sub 'Servicos de aplicacao e agentes (somente leitura)'
    Tab ($svc | Where-Object { $_.Name -match "$($script:TotvsRx)|PBIEgw|PRTG|telegraf|Mesh|tacticalrmm|AnyDesk|zabbix|MSSQL|SQLAgent" -or $_.PathName -match $script:TotvsRx } | Sort-Object Name | Select-Object Name, State, StartMode, DelayedAutoStart, StartName)
    Sub 'Servicos rodando com conta de usuario (param se a senha mudar ou expirar)'
    Tab ($svc | Where-Object { $_.StartName -match '\\' -and $_.StartName -notmatch '^(NT AUTHORITY|NT SERVICE|LocalSystem)' } | Select-Object Name, StartName, State)
}

# ================================ 7. RDS E PERFIS ================================
Secao '7. ACESSO REMOTO (RDP/RDS) E PERFIS'
Rodar 'rds' {
    Sub 'Funcao RDS e licenciamento'
    $feat = Get-WindowsFeature RDS-RD-Server, RDS-Licensing, RDS-Connection-Broker
    Tab ($feat | Select-Object Name, InstallState)
    $tss = Get-WmiObject -Namespace root\cimv2\terminalservices -Class Win32_TerminalServiceSetting
    if (($feat | Where-Object { $_.Name -eq 'RDS-RD-Server' }).InstallState -ne 'Installed') {
        Write-Host '  Funcao RDS-RD-Server NAO instalada: servidor em modo "Remote Desktop for Administration" (maximo de 2 sessoes simultaneas)'
        Alerta 'INFO' 'RDS' 'Funcao de Area de Trabalho Remota (RDS) nao instalada - so 2 sessoes RDP simultaneas e apenas para administradores'
        $tss = $null
    }
    if ($tss) {
        $ls = try { (($tss.GetSpecifiedLicenseServerList()).SpecifiedLSList) -join ', ' } catch { '' }
        $gr = try { ($tss.GetGracePeriodDays()).DaysLeft } catch { '?' }
        Lst ([pscustomobject]@{ ModoLicenca = $tss.LicensingName; ServidoresDeLicenca = $ls; DiasDeCarencia = $gr })
        if (($feat | Where-Object { $_.Name -eq 'RDS-RD-Server' }).InstallState -eq 'Installed') {
            if ($tss.LicensingType -eq 5 -or -not $ls) { Alerta 'CRITICO' 'RDS' "Licenciamento RDS nao configurado (modo: $($tss.LicensingName); servidor de licenca: $(if ($ls) { $ls } else { 'nenhum' })) - acesso remoto pode ser bloqueado ao fim da carencia ($gr dias)" }
        }
    }
    $lic = Ev System @(1128, 1129, 1130, 1131) 30 -Provider 'Microsoft-Windows-TerminalServices-RemoteConnectionManager'
    if ($lic.Count) { Tab ($lic | Select-Object -First 5 TimeCreated, Id, @{ n = 'Msg'; e = { Msg1 $_ 140 } }); Alerta 'ATENCAO' 'RDS' "$($lic.Count) avisos de licenciamento RDS em 30 dias" }
    $pol = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    Write-Host ("  Limites de sessao (politica): desconectada={0} ociosa={1} ativa={2} (ms; vazio = sem limite)" -f $pol.MaxDisconnectionTime, $pol.MaxIdleTime, $pol.MaxConnectionTime)
    if (-not $pol.MaxDisconnectionTime) { Alerta 'INFO' 'RDS' 'Sem limite para sessoes desconectadas - sessoes esquecidas seguram memoria e licencas (avaliar politica)' }

    Sub 'Sessoes (query user, com limite de 20 s)'
    $q = ComTimeout { query user 2>&1 } 20
    if ("$q" -eq '__TIMEOUT__') { Alerta 'CRITICO' 'RDS' 'query user nao respondeu em 20 s - Local Session Manager travado (mesmo sintoma de 08/10)' } else { $q | ForEach-Object { Write-Host "  $_" } }
    $zumbi = Get-CimInstance Win32_Process | Group-Object SessionId | Where-Object { $_.Name -ne '0' -and -not ($_.Group.Name | Where-Object { $_ -ne 'csrss.exe' }) }
    foreach ($z in $zumbi) { Alerta 'CRITICO' 'RDS' "Sessao $($z.Name) zumbi (so csrss.exe) - bloqueia novos logons" }

    Sub 'Logons RDP - 7 dias'
    $lsm = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'; Id = 21, 22, 23, 24, 25, 39, 40, 41; StartTime = (Get-Date).AddDays(-7) })
    $nomes = @{ '21' = 'logon OK'; '22' = 'desktop carregado'; '23' = 'logoff'; '24' = 'desconectou'; '25' = 'reconectou'; '39' = 'desconectada por outra sessao'; '40' = 'desconexao (codigo)'; '41' = 'tentativa (arbitragem)' }
    Tab ($lsm | Group-Object Id | Sort-Object Name | Select-Object @{ n = 'Id'; e = { $_.Name } }, @{ n = 'Evento'; e = { $nomes[$_.Name] } }, Count)
    $pend = @{}; $dur = New-Object System.Collections.Generic.List[object]
    foreach ($e in $lsm | Sort-Object TimeCreated) {
        $sid = $null; $usr = $null
        if ($e.Message -match 'Session ID:\s*(\d+)') { $sid = $matches[1] }
        if ($e.Message -match 'User:\s*(.+)') { $usr = $matches[1].Trim() }
        if (-not $sid) { continue }
        if ($e.Id -eq 41) { $pend[$sid] = $e }
        elseif ($e.Id -eq 22 -and $pend.ContainsKey($sid)) { $dur.Add([pscustomobject]@{ Usuario = $usr; Inicio = $pend[$sid].TimeCreated; Segundos = [math]::Round(($e.TimeCreated - $pend[$sid].TimeCreated).TotalSeconds) }); $pend.Remove($sid) }
        elseif ($e.Id -eq 25 -and $pend.ContainsKey($sid)) { $pend.Remove($sid) }
    }
    if ($dur.Count) {
        Write-Host "  Tempo de logon: media $([math]::Round(($dur.Segundos | Measure-Object -Average).Average)) s em $($dur.Count) logons. Mais lentos:"
        Tab ($dur | Sort-Object Segundos -Descending | Select-Object -First 8)
        $lentos = @($dur | Where-Object { $_.Segundos -gt 120 })
        if ($lentos.Count) { Alerta 'ATENCAO' 'RDS' "$($lentos.Count) logons RDP levaram mais de 2 minutos nos ultimos 7 dias" }
    }
    $falhos = @($pend.Values | Where-Object { $_.TimeCreated -lt (Get-Date).AddMinutes(-15) })
    if ($falhos.Count -gt 3) { Alerta 'ATENCAO' 'RDS' "$($falhos.Count) tentativas de logon sem conclusao nos ultimos 7 dias" }

    Sub 'Regras de firewall por usuario (bug do Server 2016)'
    $fw = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy'
    $n1 = (Get-Item "$fw\FirewallRules").ValueCount; $n2 = (Get-Item "$fw\RestrictedServices\Configurable\System").ValueCount; $flag = (Get-ItemProperty $fw).DeleteUserAppContainersOnLogoff
    Write-Host "  FirewallRules: $n1   Configurable\System: $n2   DeleteUserAppContainersOnLogoff: $flag"
    if ($flag -ne 1) { Alerta 'ATENCAO' 'RDS' 'Correcao DeleteUserAppContainersOnLogoff desligada - regras de firewall voltam a acumular' }
    if ($n1 -gt 3000 -or $n2 -gt 3000) { Alerta 'ATENCAO' 'RDS' "Regras de firewall acumuladas (FirewallRules=$n1, Configurable\System=$n2)" }

    Sub 'Perfis de usuario'
    $lista = foreach ($p in Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special }) {
        $nm = try { (New-Object Security.Principal.SecurityIdentifier $p.SID).Translate([Security.Principal.NTAccount]).Value } catch { $p.SID }
        [pscustomobject]@{ Usuario = $nm; Pasta = $p.LocalPath; PastaExiste = (Test-Path $p.LocalPath); UltimoUso = $p.LastUseTime; Carregado = $p.Loaded; Temporario = [bool]($p.Status -band 1); Corrompido = [bool]($p.Status -band 8) }
    }
    Tab ($lista | Sort-Object UltimoUso -Descending)
    foreach ($x in $lista) {
        if (-not $x.PastaExiste) { Alerta 'ATENCAO' 'Perfis' "Perfil de $($x.Usuario) aponta para pasta inexistente ($($x.Pasta)) - no proximo logon cai em perfil TEMP (corrigir com Repair-TempProfiles.ps1 -Modo Recriar)" }
        if ($x.Corrompido) { Alerta 'CRITICO' 'Perfis' "Perfil de $($x.Usuario) marcado como corrompido" }
        if ($x.Temporario -or $x.Pasta -match '\\TEMP') { Alerta 'ATENCAO' 'Perfis' "Perfil temporario em uso: $($x.Usuario)" }
    }
    $bak = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' | Where-Object { $_.PSChildName -like '*.bak' })
    if ($bak.Count) { Alerta 'CRITICO' 'Perfis' "$($bak.Count) chave(s) .bak no ProfileList - usuario(s) caindo em perfil temporario" }
    $velhos = @($lista | Where-Object { $_.UltimoUso -and $_.UltimoUso -lt (Get-Date).AddDays(-180) })
    if ($velhos.Count) { Alerta 'INFO' 'Perfis' "$($velhos.Count) perfis sem uso ha mais de 180 dias (candidatos a limpeza no C:)" }
    $orf = @(Get-ChildItem C:\Users -Directory -Force | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $_.Name -notin 'Public', 'Default' -and $lista.Pasta -notcontains $_.FullName })
    if ($orf.Count) { Write-Host "  Pastas em C:\Users sem perfil registrado: $(($orf.Name) -join ', ')"; Alerta 'INFO' 'Perfis' "$($orf.Count) pasta(s) em C:\Users sem perfil registrado (sobras ocupando espaco)" }
    if (-not $PularTamanhos) {
        Sub 'Maiores perfis em C:\Users'
        Tab (Get-ChildItem C:\Users -Directory -Force | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } | ForEach-Object { TamanhoPasta $_.FullName } | Sort-Object GB -Descending | Select-Object -First 15)
    }
}


# ================================ 8. REDE, DOMINIO E HORA ================================
Secao '8. REDE, DOMINIO E HORA'
Rodar 'rede' {
    Sub 'Placas de rede'
    $na = @(Get-NetAdapter)
    Tab ($na | Select-Object Name, InterfaceDescription, Status, LinkSpeed, MacAddress, DriverVersionString, DriverDate)
    Tab (Get-NetAdapterStatistics | Select-Object Name, ReceivedDiscardedPackets, ReceivedPacketErrors, OutboundDiscardedPackets, OutboundPacketErrors)
    foreach ($s in Get-NetAdapterStatistics | Where-Object { $_.ReceivedPacketErrors -gt 100 -or $_.OutboundPacketErrors -gt 100 }) { Alerta 'ATENCAO' 'Rede' "Placa $($s.Name) com erros de pacote (rx $($s.ReceivedPacketErrors) / tx $($s.OutboundPacketErrors))" }
    foreach ($a in $na | Where-Object { $_.Status -eq 'Up' -and $_.LinkSpeed -match 'Mbps' }) { Alerta 'ATENCAO' 'Rede' "Placa $($a.Name) conectada a apenas $($a.LinkSpeed)" }
    $team = @(Get-NetLbfoTeam)
    if ($team.Count) { Tab ($team | Select-Object Name, Status, TeamingMode, LoadBalancingAlgorithm, @{ n = 'Membros'; e = { $_.Members -join ', ' } }); foreach ($t in $team | Where-Object { $_.Status -ne 'Up' }) { Alerta 'CRITICO' 'Rede' "Team de rede $($t.Name) com status $($t.Status)" } }
    elseif (@($na | Where-Object { $_.Status -eq 'Up' }).Count -le 1) { Alerta 'INFO' 'Rede' 'Apenas uma placa de rede ativa e sem team - sem redundancia de rede' }

    Sub 'IP, gateway e DNS'
    $ipc = @(Get-NetIPConfiguration | Where-Object { $_.IPv4Address })
    Tab ($ipc | Select-Object InterfaceAlias, @{ n = 'IP'; e = { ($_.IPv4Address.IPAddress) -join ', ' } }, @{ n = 'Gateway'; e = { $_.IPv4DefaultGateway.NextHop } }, @{ n = 'DNS'; e = { ($_.DNSServer | Where-Object AddressFamily -eq 2).ServerAddresses -join ', ' } })
    if (@($ipc | Where-Object { $_.IPv4DefaultGateway }).Count -gt 1) { Alerta 'ATENCAO' 'Rede' 'Mais de uma placa com gateway padrao (rotas ambiguas)' }
    foreach ($i in $ipc | Where-Object { $_.IPv4DefaultGateway }) {
        $dns = @(($i.DNSServer | Where-Object AddressFamily -eq 2).ServerAddresses)
        if ($dns.Count -lt 2) { Alerta 'ATENCAO' 'Rede' "Interface $($i.InterfaceAlias) com apenas $($dns.Count) servidor DNS (sem redundancia)" }
        if (-not (Test-Connection $i.IPv4DefaultGateway.NextHop -Count 2 -Quiet)) { Alerta 'ATENCAO' 'Rede' "Gateway $($i.IPv4DefaultGateway.NextHop) nao responde a ping" }
    }
    Sub 'Quedas de link fora de boot/desligamento - 30 dias'
    $bt = @((Ev System @(6005, 6006) 30).TimeCreated)
    $ld = @(Ev System 27 30 | Where-Object { $_.ProviderName -notmatch 'Kernel-Boot' } | Where-Object { $t = $_.TimeCreated; -not ($bt | Where-Object { $t -ge $_.AddMinutes(-10) -and $t -le $_.AddMinutes(10) }) })
    Tab ($ld | Select-Object -First 15 TimeCreated, ProviderName, @{ n = 'Msg'; e = { Msg1 $_ 120 } })
    if ($ld.Count) { Alerta 'ATENCAO' 'Rede' "$($ld.Count) quedas de link de rede fora de reinicializacoes em 30 dias (cabo/porta/switch)" }

    Sub 'Dominio'
    $dcInfo = ComTimeout { nltest /dsgetdc: 2>&1 } 20
    $dcInfo | ForEach-Object { Write-Host "  $_" }
    $dcm = $dcInfo | Select-String 'DC: \\\\(\S+)' | Select-Object -First 1
    $dc = if ($dcm) { $dcm.Matches[0].Groups[1].Value }
    $scr = "$(ComTimeout { Test-ComputerSecureChannel } 30)"
    Write-Host "  Canal seguro com o dominio: $scr"
    if ($scr -eq 'False') { Alerta 'CRITICO' 'Rede' 'Relacao de confianca com o dominio QUEBRADA (Test-ComputerSecureChannel = False)' }
    elseif ($scr -eq '__TIMEOUT__') { Alerta 'ATENCAO' 'Rede' 'Teste do canal seguro com o dominio nao respondeu' }

    Sub 'Hora'
    w32tm /query /status 2>&1 | ForEach-Object { Write-Host "  $_" }
    $src = "$(w32tm /query /source 2>&1)".Trim()
    if ($src -match 'Local CMOS Clock|Free-running') { Alerta 'ATENCAO' 'Rede' "Relogio sem sincronismo externo (fonte: $src)" }
    if ($dc) {
        $offs = w32tm /stripchart /computer:$dc /samples:3 /dataonly 2>&1 | Select-String ',\s*([+-]?\d+[\.,]\d+)s' | ForEach-Object { [double]::Parse(($_.Matches[0].Groups[1].Value -replace ',', '.'), [Globalization.CultureInfo]::InvariantCulture) }
        if ($offs) {
            $o = ($offs | Measure-Object -Average).Average
            Write-Host ("  Diferenca de hora para o DC {0}: {1:N3} s" -f $dc, $o)
            if ([math]::Abs($o) -gt 60) { Alerta 'CRITICO' 'Rede' ("Hora difere {0:N0} s do DC (Kerberos falha acima de 300 s)" -f $o) }
            elseif ([math]::Abs($o) -gt 5) { Alerta 'ATENCAO' 'Rede' ("Hora difere {0:N1} s do DC" -f $o) }
        }
    }
}

# ================================ 9. SEGURANCA E ATUALIZACOES ================================
Secao '9. SEGURANCA E ATUALIZACOES'
Rodar 'seguranca' {
    Sub 'Antivirus'
    $mp = Get-MpComputerStatus
    Tab (Get-Service WinDefend, WdNisSvc, Sense | Select-Object Name, Status, StartType)
    if ($mp) { Lst ($mp | Select-Object AMServiceEnabled, AntivirusEnabled, RealTimeProtectionEnabled, AntivirusSignatureLastUpdated, QuickScanEndTime) }
    $pol = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
    Write-Host "  Politica Defender: DisableAntiSpyware=$($pol.DisableAntiSpyware) DisableAntiVirus=$($pol.DisableAntiVirus)"
    $outros = @(Get-Service | Where-Object { $_.DisplayName -match 'Sophos|ESET|McAfee|Trellix|Symantec|Endpoint Protection|SentinelOne|CrowdStrike|Falcon|Trend Micro|Bitdefender|Avast|AVG|Webroot|Cylance|Panda|Kaspersky|Carbon Black|Cortex' })
    Tab ($outros | Select-Object Name, DisplayName, Status, StartType)
    $avOutro = @($outros | Where-Object { $_.Status -eq 'Running' -and $_.DisplayName -notmatch 'Security Center|Agente de Rede|Network Agent|proxy' })
    if (-not (($mp -and $mp.RealTimeProtectionEnabled) -or $avOutro.Count)) { Alerta 'CRITICO' 'Seguranca' 'SERVIDOR SEM ANTIVIRUS ATIVO (Defender desligado e nenhum outro produto rodando)' }
    elseif ($mp -and $mp.RealTimeProtectionEnabled -and $mp.AntivirusSignatureLastUpdated -lt (Get-Date).AddDays(-3)) { Alerta 'ATENCAO' 'Seguranca' 'Assinaturas do Defender desatualizadas ha mais de 3 dias' }
    $kl = @($outros | Where-Object { $_.DisplayName -match 'Kaspersky' }) + @(Get-Process klcsldcl, klnagent, avp)
    if ($kl.Count) { Alerta 'INFO' 'Seguranca' 'Restos do Kaspersky ainda instalados/rodando (agente de rede/proxy)' }

    Sub 'Firewall do Windows'
    $fwp = @(Get-NetFirewallProfile)
    Tab ($fwp | Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction)
    foreach ($p in $fwp | Where-Object { -not $_.Enabled }) { Alerta 'INFO' 'Seguranca' "Firewall do Windows desligado no perfil $($p.Name)" }

    Sub 'Administradores locais'
    $adm = try { Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | Select-Object Name, ObjectClass, PrincipalSource } catch { net localgroup administrators }
    if ($adm -is [array] -and $adm[0] -is [string]) { $adm | ForEach-Object { Write-Host "  $_" } } else { Tab $adm }
    Sub 'Contas locais'
    Tab (Get-LocalUser | Select-Object Name, Enabled, PasswordLastSet, PasswordExpires, LastLogon)

    Sub 'RDP e SMB'
    $rdp = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
    Write-Host "  RDP porta: $($rdp.PortNumber)  NLA (UserAuthentication): $($rdp.UserAuthentication)  SecurityLayer: $($rdp.SecurityLayer)"
    if ($rdp.UserAuthentication -ne 1) { Alerta 'ATENCAO' 'Seguranca' 'RDP sem autenticacao em nivel de rede (NLA) - mais exposto a ataques' }
    $smb = Get-SmbServerConfiguration
    Write-Host "  SMBv1: $($smb.EnableSMB1Protocol)  SMBv2: $($smb.EnableSMB2Protocol)  Assinatura obrigatoria: $($smb.RequireSecuritySignature)"
    if ($smb.EnableSMB1Protocol) { Alerta 'ATENCAO' 'Seguranca' 'SMBv1 habilitado (protocolo explorado pelo WannaCry) - avaliar desligar' }
    $sh = @(Get-SmbShare | Where-Object { $_.Name -notmatch '\$$' })
    Tab ($sh | Select-Object Name, Path, Description)
    foreach ($s in $sh) { if (Get-SmbShareAccess -Name $s.Name | Where-Object { $_.AccountName -match 'Everyone|Todos' -and $_.AccessRight -eq 'Full' -and $_.AccessControlType -eq 'Allow' }) { Alerta 'ATENCAO' 'Seguranca' "Compartilhamento '$($s.Name)' com controle total para Everyone/Todos" } }

    Sub 'Tentativas de logon com falha (4625) - 7 dias'
    $f = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4625; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 20000)
    Write-Host "  Total: $($f.Count)"
    if ($f.Count) {
        Tab ($f | Group-Object { $_.Properties[5].Value } | Sort-Object Count -Descending | Select-Object -First 10 Count, @{ n = 'Conta'; e = { $_.Name } })
        Tab ($f | Group-Object { $_.Properties[19].Value } | Sort-Object Count -Descending | Select-Object -First 10 Count, @{ n = 'IP de origem'; e = { $_.Name } })
    }
    if ($f.Count -gt 500) { Alerta 'ATENCAO' 'Seguranca' "$($f.Count) logons com falha em 7 dias - verificar forca bruta (ver contas e IPs)" }

    Sub 'Atualizacoes do Windows'
    $hf = @(Get-HotFix | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending)
    Tab ($hf | Select-Object -First 8 HotFixID, Description, InstalledOn)
    if ($hf.Count) {
        $d = ((Get-Date) - $hf[0].InstalledOn).Days
        if ($d -gt 90) { Alerta 'CRITICO' 'Atualizacoes' "Ultima atualizacao instalada ha $d dias" } elseif ($d -gt 45) { Alerta 'ATENCAO' 'Atualizacoes' "Ultima atualizacao instalada ha $d dias" }
    }
    $wuf = Ev System 20 30 -Provider 'Microsoft-Windows-WindowsUpdateClient'
    if ($wuf.Count) { Tab ($wuf | Select-Object -First 5 TimeCreated, @{ n = 'Msg'; e = { Msg1 $_ 140 } }); Alerta 'ATENCAO' 'Atualizacoes' "$($wuf.Count) falhas de instalacao do Windows Update em 30 dias" }
    $wu = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; $au = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    Write-Host "  WSUS: $($wu.WUServer)  AUOptions: $($au.AUOptions)  NoAutoUpdate: $($au.NoAutoUpdate)"
    $pend = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pend += 'Windows Update' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pend += 'CBS' }
    if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager').PendingFileRenameOperations) { $pend += 'arquivos pendentes' }
    Write-Host "  Reinicio pendente: $(if ($pend) { $pend -join ', ' } else { 'nao' })"
    if ($pend -contains 'Windows Update' -or $pend -contains 'CBS') { Alerta 'ATENCAO' 'Atualizacoes' "Reinicio pendente para concluir atualizacoes ($($pend -join ', '))" }

    Sub 'Certificados da maquina'
    $certs = @(Get-ChildItem Cert:\LocalMachine\My) + @(Get-ChildItem 'Cert:\LocalMachine\Remote Desktop')
    Tab ($certs | Select-Object @{ n = 'Repositorio'; e = { Split-Path $_.PSParentPath -Leaf } }, Subject, NotAfter, @{ n = 'Dias'; e = { ($_.NotAfter - (Get-Date)).Days } })
    foreach ($c in $certs | Where-Object { (Split-Path $_.PSParentPath -Leaf) -eq 'My' }) {
        $dd = ($c.NotAfter - (Get-Date)).Days
        if ($dd -ge 0 -and $dd -lt 30) { Alerta 'ATENCAO' 'Seguranca' "Certificado '$($c.Subject)' vence em $dd dias" }
    }
}


# ================================ 10. BACKUP ================================
Secao '10. BACKUP'
Rodar 'backup' {
    Sub 'Disco de backup (G:)'
    $gd = Get-Partition -DriveLetter G | Get-Disk
    if ($gd) { Tab ($gd | Select-Object Number, FriendlyName, BusType, HealthStatus, OperationalStatus, @{ n = 'GB'; e = { [math]::Round($_.Size / 1GB) } }) }
    Sub 'Pastas de backup em G:\ - arquivo mais recente de cada uma'
    $alvos = @(Get-ChildItem 'G:\' -Directory -Force | Where-Object { $_.Name -match 'BACKUP|BKP' })
    $res = foreach ($a in $alvos) {
        $arqs = @(Get-ChildItem $a.FullName -File -Recurse -Depth 3 -Force)
        $ult = $arqs | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        [pscustomobject]@{ Pasta = $a.Name; Arquivos = $arqs.Count; TotalGB = [math]::Round((($arqs | Measure-Object Length -Sum).Sum) / 1GB, 1); MaisRecente = $ult.Name; Data = $ult.LastWriteTime; HorasAtras = if ($ult) { [math]::Round(((Get-Date) - $ult.LastWriteTime).TotalHours) } }
    }
    Tab $res
    $bd = $res | Where-Object { $_.Pasta -eq 'BACKUP-BD' }
    if ($bd) {
        if ($bd.HorasAtras -gt 72) { Alerta 'CRITICO' 'Backup' "Backup do banco (G:\BACKUP-BD) mais recente tem $($bd.HorasAtras) horas" }
        elseif ($bd.HorasAtras -gt 30) { Alerta 'ATENCAO' 'Backup' "Backup do banco (G:\BACKUP-BD) mais recente tem $($bd.HorasAtras) horas" }
        Sub 'G:\BACKUP-BD - 10 arquivos mais recentes'
        Tab (Get-ChildItem 'G:\BACKUP-BD' -File -Recurse -Depth 3 -Force | Sort-Object LastWriteTime -Descending | Select-Object -First 10 FullName, @{ n = 'GB'; e = { [math]::Round($_.Length / 1GB, 2) } }, LastWriteTime)
    }
    if ($gd -and "$($gd.BusType)" -eq 'USB') { Alerta 'ATENCAO' 'Backup' 'Backups ficam em disco USB ligado no proprio servidor - confirmar se existe copia fora do servidor (falha fisica, roubo ou ransomware levam producao e backup juntos)' }

    Sub 'VSS writers (base de qualquer backup do Windows/SQL)'
    $lst = New-Object System.Collections.Generic.List[object]; $cur = $null
    foreach ($l in (vssadmin list writers 2>&1)) {
        if ($l -match "Writer name: '(.+)'") { if ($cur) { $lst.Add($cur) }; $cur = [pscustomobject]@{ Writer = $matches[1]; Estado = ''; UltimoErro = '' } }
        elseif ($cur -and $l -match 'State: \[\d+\] (.+)') { $cur.Estado = $matches[1].Trim() }
        elseif ($cur -and $l -match 'Last error: (.+)') { $cur.UltimoErro = $matches[1].Trim() }
    }
    if ($cur) { $lst.Add($cur) }
    Tab $lst
    $ruins = @($lst | Where-Object { $_.Estado -ne 'Stable' -or $_.UltimoErro -ne 'No error' })
    if ($ruins.Count) { Alerta 'ATENCAO' 'Backup' "VSS writers com problema: $(($ruins.Writer) -join ', ')" }

    Sub 'Software de backup instalado'
    Tab (Get-Service | Where-Object { $_.DisplayName -match 'Veeam|Backup|Acronis|Commvault|Arcserve|Cobian|Bacula|UrBackup|Synology|Active Backup|Duplicati' } | Select-Object Name, DisplayName, Status, StartType)
}

# ================================ 11. TAREFAS AGENDADAS ================================
Secao '11. TAREFAS AGENDADAS (fora da Microsoft)'
Rodar 'tarefas' {
    $lin = foreach ($t in Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' }) {
        $i = $t | Get-ScheduledTaskInfo
        [pscustomobject]@{ Tarefa = $t.TaskName; Estado = $t.State; Usuario = $t.Principal.UserId; Ultima = $i.LastRunTime; Resultado = ('0x{0:X}' -f $i.LastTaskResult); Proxima = $i.NextRunTime; Acao = (($t.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)".Trim() }) -join ' ; ') }
    }
    Tab ($lin | Select-Object Tarefa, Estado, Usuario, Ultima, Resultado, Proxima)
    Tab ($lin | Select-Object Tarefa, @{ n = 'Acao'; e = { if ($_.Acao.Length -gt 170) { $_.Acao.Substring(0, 170) + '...' } else { $_.Acao } } })
    $okCodes = '0x0', '0x41301', '0x41303', '0x41325', '0x8004131F'
    foreach ($x in $lin | Where-Object { $_.Estado -ne 'Disabled' -and $_.Resultado -notin $okCodes -and $_.Ultima -and $_.Ultima.Year -gt 2000 }) { Alerta 'ATENCAO' 'Tarefas' "Tarefa '$($x.Tarefa)' terminou com erro $($x.Resultado) em $($x.Ultima)" }
}

# ================================ 12. EVENTOS ================================
Secao '12. EVENTOS - resumo'
Rodar 'eventos' {
    foreach ($log in 'System', 'Application') {
        Sub "$log - erros e criticos dos ultimos 7 dias (agrupados)"
        $e = Ev $log -Dias 7 -Level 1, 2
        Tab ($e | Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object -First 25 Count, @{ n = 'Origem'; e = { $_.Name } }, @{ n = 'Ultimo'; e = { ($_.Group | Sort-Object TimeCreated -Descending)[0].TimeCreated } }, @{ n = 'Exemplo'; e = { Msg1 $_.Group[0] 110 } })
    }
    Sub 'Aplicacoes que travaram ou cairam (1000/1002) - 30 dias'
    $ap = @(Ev Application @(1000, 1002) 30 -Provider 'Application Error', 'Application Hang')
    $g = @($ap | Group-Object { $_.Properties[0].Value } | Sort-Object Count -Descending)
    Tab ($g | Select-Object Count, @{ n = 'Aplicacao'; e = { $_.Name } }, @{ n = 'Ultima'; e = { ($_.Group | Sort-Object TimeCreated -Descending)[0].TimeCreated } })
    foreach ($x in $g | Where-Object { $_.Count -ge 3 }) {
        $tot = if ($x.Name -match 'appserver|dbaccess|totvs|smartclient|\.dyncall') { ' (TOTVS - repassar ao suporte TOTVS)' } else { '' }
        Alerta 'ATENCAO' 'Aplicacoes' "$($x.Name) travou/caiu $($x.Count)x em 30 dias$tot"
    }
    $rx = Ev System 2004 30 -Provider 'Microsoft-Windows-Resource-Exhaustion-Detector'
    if ($rx.Count) { Alerta 'CRITICO' 'Desempenho' "$($rx.Count) alertas de memoria virtual esgotada (2004) em 30 dias" }
}

Finaliza
