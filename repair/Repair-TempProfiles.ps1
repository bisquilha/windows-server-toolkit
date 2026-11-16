<#
.SYNOPSIS
    Corrige usuários entrando com PERFIL TEMPORÁRIO (eventos 1511/1515) sem reiniciar o servidor.
.DESCRIPTION
    Após reset forçado o Windows marca o perfil como problemático: renomeia a chave do
    usuário em ProfileList para <SID>.bak e passa a logar ele em C:\Users\TEMP.*
    A correção é: apagar a chave temporária, renomear <SID>.bak -> <SID>, zerar State/RefCount.
    O usuário PRECISA estar deslogado no momento da correção (o script pula quem estiver logado).
.PARAMETER Modo
    Listar   (padrão) - só mostra a situação, não altera nada
    Corrigir - corrige as chaves .bak dos usuários deslogados (faz backup do registro antes)
    Limpar   - apaga as pastas C:\Users\TEMP* que não estão em uso
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Downloads\Repair-TempProfiles.ps1"
    powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Downloads\Repair-TempProfiles.ps1" -Modo Corrigir
#>
param(
    [ValidateSet('Listar','Corrigir','Recriar','Limpar')]
    [string]$Modo = 'Listar'
)

$ErrorActionPreference = 'Continue'
$PL = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -ErrorAction SilentlyContinue | Out-Null

function Nome-SID($sid) {
    try { (New-Object Security.Principal.SecurityIdentifier $sid).Translate([Security.Principal.NTAccount]).Value } catch { '?' }
}
function Logado($sid) { Test-Path "HKU:\$sid" }   # hive carregado = usuário logado (ou hive preso)

function Levanta {
    $chaves = Get-ChildItem $PL | Where-Object { $_.PSChildName -match '^S-1-5-21-' }
    $sids = $chaves.PSChildName -replace '\.bak$','' | Sort-Object -Unique
    foreach ($sid in $sids) {
        $kBak = Get-ItemProperty "$PL\$sid.bak" -ErrorAction SilentlyContinue
        $kAtu = Get-ItemProperty "$PL\$sid"     -ErrorAction SilentlyContinue
        $temProblema = $kBak -or ($kAtu.ProfileImagePath -match '\\TEMP') -or ($kAtu.State -band 0x800) -or ($kAtu.State -band 0x100)
        if (-not $temProblema) { continue }
        $real = if ($kBak) { $kBak.ProfileImagePath } else { $kAtu.ProfileImagePath }
        $ntuser = Join-Path $real 'NTUSER.DAT'
        [pscustomobject]@{
            Usuario      = Nome-SID $sid
            SID          = $sid
            TemBak       = [bool]$kBak
            CaminhoAtual = $kAtu.ProfileImagePath
            CaminhoReal  = $real
            NTUSER_KB    = if (Test-Path $ntuser) { [math]::Round((Get-Item $ntuser -Force).Length/1KB) } else { 'FALTA' }
            State        = $kAtu.State
            Logado       = Logado $sid
        }
    }
}

Write-Host "`n==== PERFIS COM PROBLEMA ====" -ForegroundColor Cyan
$lista = @(Levanta)
if (-not $lista) { Write-Host "  Nenhum perfil .bak / TEMP encontrado." -ForegroundColor Green }
else { $lista | Format-Table -AutoSize | Out-String -Width 300 | Write-Host }

Write-Host "==== PASTAS TEMP EM C:\Users ====" -ForegroundColor Cyan
Get-ChildItem C:\Users -Directory -Force | Where-Object Name -like 'TEMP*' |
    Select-Object FullName, LastWriteTime | Format-Table -AutoSize | Out-String | Write-Host


switch ($Modo) {
'Listar' {
    Write-Host "`nNada foi alterado. Usuários com Logado=True precisam fazer LOGOFF (não basta desconectar)." -ForegroundColor Yellow
    Write-Host "Para derrubar uma sessão: logoff <ID>   (ID da coluna acima)" -ForegroundColor Yellow
    Write-Host "NTUSER_KB = FALTA ou 0 -> perfil original danificado, me avise antes de corrigir esse." -ForegroundColor Yellow
}

'Corrigir' {
    $bk = "C:\Temp\ProfileList_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').reg"
    New-Item -ItemType Directory -Force C:\Temp | Out-Null
    reg export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" $bk /y | Out-Null
    Write-Host "`nBackup do registro: $bk" -ForegroundColor Green

    foreach ($p in $lista) {
        Write-Host "`n--- $($p.Usuario) ---"
        if ($p.Logado)                 { Write-Host "  PULADO: está logado. Faça logoff dele e rode de novo." -ForegroundColor Yellow; continue }
        if ($p.NTUSER_KB -eq 'FALTA' -or $p.NTUSER_KB -eq 0) { Write-Host "  PULADO: NTUSER.DAT ausente/vazio em $($p.CaminhoReal)." -ForegroundColor Red; continue }

        if ($p.TemBak) {
            if (Test-Path "$PL\$($p.SID)") {
                Remove-Item "$PL\$($p.SID)" -Recurse -Force
                Write-Host "  Removida chave temporária $($p.SID)"
            }
            Rename-Item "$PL\$($p.SID).bak" $p.SID
            Write-Host "  $($p.SID).bak -> $($p.SID)"
        }
        Set-ItemProperty "$PL\$($p.SID)" -Name State    -Value 0 -Type DWord
        Set-ItemProperty "$PL\$($p.SID)" -Name RefCount -Value 0 -Type DWord -ErrorAction SilentlyContinue
        $atual = (Get-ItemProperty "$PL\$($p.SID)").ProfileImagePath
        Write-Host ("  OK -> perfil aponta para {0}" -f $atual) -ForegroundColor Green
        if ($atual -match '\\TEMP') { Write-Host "  ATENÇÃO: ainda aponta para TEMP, me avise." -ForegroundColor Red }
    }
    Write-Host "`nPeça para os usuários corrigidos logarem de novo. Depois rode -Modo Limpar." -ForegroundColor Cyan
}

'Recriar' {
    # Para perfis cuja pasta real NÃO existe mais: remove as duas chaves (SID e SID.bak)
    # para o Windows criar um perfil novo e limpo no próximo logon.
    $bk = "C:\Temp\ProfileList_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').reg"
    New-Item -ItemType Directory -Force C:\Temp | Out-Null
    reg export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" $bk /y | Out-Null
    Write-Host "`nBackup do registro: $bk" -ForegroundColor Green

    foreach ($p in $lista) {
        Write-Host "`n--- $($p.Usuario) ---"
        if ($p.Logado)                   { Write-Host "  PULADO: está logado. Faça logoff dele e rode de novo." -ForegroundColor Yellow; continue }
        if (Test-Path $p.CaminhoReal)    { Write-Host "  PULADO: a pasta $($p.CaminhoReal) EXISTE - use -Modo Corrigir para esse." -ForegroundColor Yellow; continue }

        $guid = (Get-ItemProperty "$PL\$($p.SID).bak" -ErrorAction SilentlyContinue).Guid
        if (-not $guid) { $guid = (Get-ItemProperty "$PL\$($p.SID)" -ErrorAction SilentlyContinue).Guid }
        foreach ($k in "$PL\$($p.SID)", "$PL\$($p.SID).bak") {
            if (Test-Path $k) { Remove-Item $k -Recurse -Force; Write-Host "  Removida: $(Split-Path $k -Leaf)" }
        }
        if ($guid) {
            $g = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileGuid\$guid"
            if (Test-Path $g) { Remove-Item $g -Recurse -Force; Write-Host "  Removida ProfileGuid $guid" }
        }
        Write-Host "  OK -> no próximo logon o Windows cria C:\Users\<usuario> novo." -ForegroundColor Green
    }
    Write-Host "`nDepois que todos logarem normalmente, rode -Modo Limpar." -ForegroundColor Cyan
}

'Limpar' {
    $emUso = Get-ChildItem $PL | ForEach-Object { (Get-ItemProperty $_.PSPath).ProfileImagePath }
    foreach ($d in Get-ChildItem C:\Users -Directory -Force | Where-Object Name -like 'TEMP*') {
        if ($emUso -contains $d.FullName) { Write-Host "  PULADO (referenciado no ProfileList, usuário logado nele): $($d.FullName)" -ForegroundColor Yellow; continue }
        # Pastas de perfil têm ACL do dono antigo e junctions: assume posse, dá acesso a Administradores e usa rd (não segue junctions)
        $p = $d.FullName
        takeown /f "$p" /r /d y *> $null
        icacls "$p" /grant '*S-1-5-32-544:F' /t /c /q *> $null
        cmd /c "rd /s /q `"$p`"" 2>$null
        if (Test-Path $p) {   # caminho longo: esvazia com robocopy
            $vazia = Join-Path $env:TEMP "_vazia_$(Get-Random)"; New-Item -ItemType Directory $vazia | Out-Null
            robocopy $vazia "$p" /MIR /R:0 /W:0 /NFL /NDL /NJH /NJS *> $null
            cmd /c "rd /s /q `"$p`"" 2>$null; Remove-Item $vazia -Force
        }
        if (Test-Path $d.FullName) { Write-Host "  NÃO removida: $($d.FullName)" -ForegroundColor Yellow }
        else                       { Write-Host "  Removida: $($d.FullName)" -ForegroundColor Green }
    }
}
}
