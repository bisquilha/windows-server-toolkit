<#
.SYNOPSIS
    Assina arquivos (.exe, .dll, .msi, .ps1, .psm1, .cab...) com o certificado de assinatura de código da
    CA interna (ex.: CORP-ROOT-CA), em que todos os PCs do domínio já confiam. Serve para qualquer app interno.

.DESCRIPTION
    - Acha sozinho o certificado em Cert:\CurrentUser\My: uso "Assinatura de código", emitido pela CA informada em
      -Emissor, com chave privada e dentro da validade (o mais novo). -Thumbprint força um específico.
    - Carimbo de tempo (timestamp) ligado por padrão: a assinatura continua válida depois que o certificado vencer
      (ele vale 1 ano). O serviço de carimbo recebe só o hash do arquivo. -SemCarimbo desliga.
    - Confere no fim: o status precisa ser "Valid" neste PC, senão dá erro (nada sai assinado pela metade).

    Por que assinar: antivírus corporativos e o SmartScreen tratam app interno assinado por uma CA confiável como
    confiável; sem assinatura ele pode cair em regras restritivas (sem acesso a microfone, rede etc.).

.PARAMETER Emissor
    Issuer (DN) da CA interna que emite os certificados de assinatura de código.
.EXAMPLE
    .\Sign-Files.ps1 -Emissor 'CN=CORP-ROOT-CA, DC=corp, DC=example, DC=com' -Arquivos .\publicar\MeuApp.exe
.EXAMPLE
    .\Sign-Files.ps1 -Thumbprint 0123ABCD... -Arquivos .\script.ps1, .\instalador.msi -SemCarimbo
#>
param(
    [Parameter(Mandatory)][string[]]$Arquivos,
    [string]$Emissor,
    [string]$Thumbprint,
    [switch]$SemCarimbo,
    [string[]]$ServidoresCarimbo = @('http://timestamp.digicert.com', 'http://timestamp.sectigo.com', 'http://timestamp.globalsign.com/tsa/r6advanced1')
)
$ErrorActionPreference = 'Stop'
if (-not $Emissor -and -not $Thumbprint) { throw 'Informe -Emissor (DN da CA interna) ou -Thumbprint do certificado.' }
$EmissorEsperado = $Emissor

$certs = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Where-Object { $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) }
$cert = if ($Thumbprint) { $certs | Where-Object Thumbprint -eq $Thumbprint.Replace(' ', '').ToUpperInvariant() }
        else { $certs | Where-Object Issuer -eq $EmissorEsperado | Sort-Object NotAfter -Descending | Select-Object -First 1 }
if (-not $cert) {
    throw "Nenhum certificado de assinatura de código válido (emissor '$EmissorEsperado') em Cert:\CurrentUser\My. " +
          "Peça um (PowerShell como administrador): Get-Certificate -Template CodeSigning -CertStoreLocation Cert:\CurrentUser\My"
}
if ($cert.NotAfter -lt (Get-Date).AddDays(30)) {
    Write-Warning "O certificado vence em $($cert.NotAfter.ToString('dd/MM/yyyy')). Renove: Get-Certificate -Template CodeSigning -CertStoreLocation Cert:\CurrentUser\My (como administrador)."
}

foreach ($arq in $Arquivos) {
    $caminho = (Resolve-Path $arq).Path
    $r = $null
    if ($SemCarimbo) {
        $r = Set-AuthenticodeSignature -FilePath $caminho -Certificate $cert -HashAlgorithm SHA256
    } else {
        foreach ($ts in $ServidoresCarimbo) {
            try {
                $r = Set-AuthenticodeSignature -FilePath $caminho -Certificate $cert -HashAlgorithm SHA256 -TimestampServer $ts
                if ($r.Status -eq 'Valid' -and $r.TimeStamperCertificate) { break }
            } catch { Write-Warning "Carimbo de tempo falhou em ${ts}: $($_.Exception.Message)" }
        }
    }
    $sig = Get-AuthenticodeSignature $caminho
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Thumbprint -ne $cert.Thumbprint) {
        throw "Assinatura de '$caminho' não ficou válida: $($sig.Status) - $($sig.StatusMessage)"
    }
    $carimbo = if ($sig.TimeStamperCertificate) { 'com carimbo de tempo' } else { 'SEM carimbo de tempo (vale só até o certificado vencer)' }
    Write-Host "Assinado: $(Split-Path $caminho -Leaf) - $carimbo" -ForegroundColor Green
}
[pscustomobject]@{ Certificado = $cert.Subject; Thumbprint = $cert.Thumbprint; ValidoAte = $cert.NotAfter }
