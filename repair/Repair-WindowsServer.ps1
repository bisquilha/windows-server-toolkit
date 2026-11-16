<#
.SYNOPSIS
    Reparos do Windows no SERVIDOR01 com o servidor LIGADO. NUNCA reinicia o servidor.
    Nao mexe em Protheus, SQL Server nem em servicos/pastas da TOTVS.
.PARAMETER Etapa
    Reparo     - C3: DISM /RestoreHealth + sfc /scannow (30-60 min, gera carga de disco/CPU)
    Ajustes    - I2: hora pelo dominio | A12: liga a AUDITORIA do SMBv1 (so registra, nao desliga)
                 I3: remove servicos e tarefas do Google que apontam para programas inexistentes (com backup)
    NLA        - A12: exige NLA para NOVAS conexoes RDP (a sessao atual nao cai)
    DesfazerNLA- volta o RDP como estava antes
    Verificar  - mostra o estado de tudo acima (so leitura)
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Downloads\Repair-WindowsServer.ps1" -Etapa Reparo
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Reparo', 'Ajustes', 'NLA', 'DesfazerNLA', 'Verificar')]
    [string]$Etapa
)

$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force C:\Temp | Out-Null
$ts = Get-Date -Format 'yyyyMMdd_HHmm'
$bkDir = "C:\Temp\Reparo_backup_$ts"
Start-Transcript "C:\Temp\Reparo_${Etapa}_$ts.txt" -Force | Out-Null
function Titulo($t) { Write-Host "`n==== $t  [$(Get-Date -Format 'HH:mm:ss')] ====" -ForegroundColor Cyan }
function Ok($t)     { Write-Host "  OK  $t" -ForegroundColor Green }
function Aviso($t)  { Write-Host "  !!  $t" -ForegroundColor Yellow }
function Erro($t)   { Write-Host "  XX  $t" -ForegroundColor Red }

$rdpKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'

function Estado {
    Titulo 'ESTADO ATUAL'
    $pend = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pend += 'CBS (reparo/atualizacao)' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pend += 'Windows Update' }
    if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue).PendingFileRenameOperations) { $pend += 'arquivos a substituir' }
    Write-Host "  Reinicio pendente: $(if ($pend) { $pend -join ', ' } else { 'nao' })"
    Write-Host "  Fonte de hora: $((w32tm /query /source 2>&1) -join ' ')"
    $smb = Get-SmbServerConfiguration
    Write-Host "  SMBv1 ligado: $($smb.EnableSMB1Protocol)   Auditoria SMBv1: $($smb.AuditSmb1Access)"
    $a = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-SMBServer/Audit'; Id = 3000 } -MaxEvents 200 -ErrorAction SilentlyContinue)
    if ($a.Count) { Write-Host "  Acessos SMBv1 registrados: $($a.Count) - clientes:"; $a | ForEach-Object { if ($_.Message -match 'Client Address:\s*(\S+)') { $matches[1] } } | Group-Object | Sort-Object Count -Descending | ForEach-Object { Write-Host "     $($_.Name)  ($($_.Count)x)" } }
    Write-Host "  RDP NLA (UserAuthentication): $((Get-ItemProperty $rdpKey).UserAuthentication)"
    $g = @(Get-CimInstance Win32_Service | Where-Object { $_.Name -match '^(gupdate|gupdatem|GoogleUpdater)' })
    Write-Host "  Servicos Google restantes: $(if ($g) { ($g.Name) -join ', ' } else { 'nenhum' })"
    Write-Host "  Acesso alternativo: $((Get-Service AnyDesk, 'Mesh Agent', tacticalrmm -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join '  ')"
}

switch ($Etapa) {

'Verificar' { Estado }

'Reparo' {
    Titulo 'C3 - 1/2 DISM /RestoreHealth (repara o repositorio do Windows, 15-40 min)'
    Write-Host '  Nao reinicia nada. Pode ficar parado em alguns % por varios minutos - e normal.'
    DISM.exe /Online /Cleanup-Image /RestoreHealth
    $rc = $LASTEXITCODE
    if ($rc -eq 0) { Ok 'DISM concluiu: repositorio reparado' }
    elseif ($rc -eq -2146498529 -or $rc -eq 0x800f081f) { Erro 'DISM nao encontrou os arquivos de origem (0x800f081f). Precisamos de uma ISO do Windows Server 2016 como fonte - PAROU AQUI, me avise.'; Stop-Transcript | Out-Null; return }
    else { Erro ("DISM terminou com codigo 0x{0:X8} - me mande este log antes de seguir" -f $rc); Stop-Transcript | Out-Null; return }

    Titulo 'C3 - 2/2 sfc /scannow (repara os arquivos do sistema, 15-30 min)'
    $o = @(cmd /c 'sfc /scannow' 2>&1 | ForEach-Object { ("$_" -replace "`0", '').Trim() } | Where-Object { $_ -and $_ -notmatch '^Verification \d+% complete' })
    $o | Select-Object -Last 6 | ForEach-Object { Write-Host "  $_" }
    $txt = $o -join ' '
    if ($txt -match 'did not find any integrity violations') { Ok 'SFC: nenhuma violacao encontrada' }
    elseif ($txt -match 'successfully repaired') { Ok 'SFC: arquivos corrompidos encontrados e REPARADOS' }
    elseif ($txt -match 'unable to fix some') { Aviso 'SFC: alguns arquivos NAO puderam ser reparados (detalhes abaixo)' }
    elseif ($txt -match 'repair pending') { Aviso 'SFC: existe um reparo pendente que exige reinicio - NAO reinicie agora, fica para a janela' }
    else { Aviso 'SFC: resultado nao reconhecido (ver texto acima)' }

    Titulo 'Detalhes do SFC (CBS.log - linhas [SR] desta execucao)'
    $cbs = "$env:windir\Logs\CBS\CBS.log"
    $copia = "C:\Temp\CBS_$ts.log"
    Copy-Item $cbs $copia -ErrorAction SilentlyContinue
    $sr = @(Select-String -Path $copia -Pattern '\[SR\]' -ErrorAction SilentlyContinue | Where-Object { $_.Line -match 'Repair|Cannot|corrupt|hash' })
    $hoje = Get-Date -Format 'yyyy-MM-dd'
    $sr = @($sr | Where-Object { $_.Line -like "$hoje*" })
    if ($sr.Count) { $sr | Select-Object -Last 30 | ForEach-Object { Write-Host "  $($_.Line.Substring(0, [Math]::Min(250, $_.Line.Length)))" } } else { Write-Host '  (sem linhas de reparo hoje)' }
    Write-Host "  Copia do CBS.log: $copia"
    Estado
    Write-Host "`n  O servidor NAO foi reiniciado. Se aparecer reinicio pendente, ele fica para a proxima janela de manutencao." -ForegroundColor Cyan
}

'Ajustes' {
    New-Item -ItemType Directory -Force $bkDir | Out-Null

    Titulo 'I2 - Hora sincronizada pelo dominio'
    $polT = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\W32Time\Parameters' -ErrorAction SilentlyContinue
    if ($polT -and ($polT.NtpServer -or $polT.Type)) {
        Aviso "Hora definida por GPO (Type=$($polT.Type) NtpServer=$($polT.NtpServer)) - nao alterado aqui; ajustar na GPO."
    } else {
        reg export 'HKLM\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' "$bkDir\W32Time.reg" /y | Out-Null
        w32tm /config /syncfromflags:domhier /update | Out-Null
        Restart-Service w32time
        Start-Sleep 3
        w32tm /resync /force | Out-Null
        Start-Sleep 3
        Ok "Fonte de hora agora: $((w32tm /query /source 2>&1) -join ' ')"
    }

    Titulo 'A12 - Auditoria do SMBv1 (so registra quem usa; NAO desliga)'
    Set-SmbServerConfiguration -AuditSmb1Access $true -Force
    Ok "AuditSmb1Access = $((Get-SmbServerConfiguration).AuditSmb1Access)  - em 7 dias rode -Etapa Verificar para ver quem usa SMBv1"

    Titulo 'I3 - Servicos do Google sem programa (orfaos)'
    foreach ($s in Get-CimInstance Win32_Service | Where-Object { $_.Name -match '^(gupdate|gupdatem|GoogleUpdater)' }) {
        $m = [regex]::Match("$($s.PathName)", '^"?([^"]+?\.exe)', 'IgnoreCase')
        if ($m.Success -and -not (Test-Path -LiteralPath $m.Groups[1].Value)) {
            reg export "HKLM\SYSTEM\CurrentControlSet\Services\$($s.Name)" "$bkDir\svc_$($s.Name).reg" /y | Out-Null
            sc.exe delete $s.Name | Out-Null
            Ok "Removido servico orfao: $($s.Name)"
        } else { Write-Host "  Mantido (programa existe): $($s.Name)" }
    }

    Titulo 'I3 - Tarefas agendadas do Google sem programa (orfas)'
    foreach ($t in Get-ScheduledTask | Where-Object { $_.TaskName -match '^(GoogleUpdaterTaskSystem|RunPlatformExperienceHelper)' }) {
        $exe = ($t.Actions | Select-Object -First 1).Execute -replace '"', ''
        if ($exe -and -not (Test-Path -LiteralPath $exe)) {
            Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath | Out-File "$bkDir\task_$($t.TaskName -replace '[{}]', '').xml" -Encoding Unicode
            Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false
            Ok "Removida tarefa orfa: $($t.TaskName)"
        } else { Write-Host "  Mantida (programa existe): $($t.TaskName)" }
    }
    Write-Host "`n  Backups do que foi alterado/removido: $bkDir" -ForegroundColor Cyan
    Estado
}

'NLA' {
    Titulo 'A12 - Exigir NLA no RDP (vale para NOVAS conexoes)'
    New-Item -ItemType Directory -Force $bkDir | Out-Null
    reg export 'HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' "$bkDir\RDP-Tcp.reg" /y | Out-Null
    Set-ItemProperty $rdpKey -Name UserAuthentication -Value 1 -Type DWord
    Ok "UserAuthentication = $((Get-ItemProperty $rdpKey).UserAuthentication)"
    Write-Host @"

  >>> NAO FECHE ESTA SESSAO <<<
  1) Abra uma NOVA conexao RDP para <ip-do-servidor>:<porta-rdp> a partir do seu PC.
  2) Se entrar normalmente: pronto.
  3) Se NAO entrar: volte nesta sessao e rode -Etapa DesfazerNLA
     (se perder esta sessao, o AnyDesk/Mesh continuam disponiveis para desfazer).
"@ -ForegroundColor Yellow
}

'DesfazerNLA' {
    Titulo 'Desfazendo NLA'
    Set-ItemProperty $rdpKey -Name UserAuthentication -Value 0 -Type DWord
    Ok "UserAuthentication = $((Get-ItemProperty $rdpKey).UserAuthentication)  (como estava antes)"
}
}

Stop-Transcript | Out-Null
