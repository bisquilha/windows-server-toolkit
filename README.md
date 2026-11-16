# Windows Server Troubleshooting Toolkit

PowerShell scripts written while running a production Windows Server that hosts an ERP (TOTVS Protheus), SQL Server and Remote Desktop for dozens of users, and that one day stopped accepting logons: *"Please wait for the Local Session Manager"*, zombie RDP sessions, temporary profiles after a forced reset, a Windows Search loop, and so on.

Each script answers one question, prints a readable report and saves a copy in `C:\Temp`. The rule behind all of them: **diagnose read-only first, change only with an explicit switch, keep a backup and a way back.**

This is a generic, sanitised version: no company names, hosts, IPs or credentials. Script output and comments are in Portuguese.

---

## Diagnostics (read-only, except where noted)

| Script | Question it answers |
|---|---|
| `diagnostics/Invoke-ServerCheckup.ps1` | Full health check of an application server: hardware log (BMC), disks and latency, memory, CPU, services, SQL Server configuration and waits, RDP, profiles, domain, updates. Produces `checkup.txt` and `alertas.csv` (CRITICO / ATENCAO / INFO). `-Integridade` adds `sfc /verifyonly`, `DISM /ScanHealth`, `chkdsk /scan`. |
| `diagnostics/Get-CrashDiagnostics.ps1` | What happened before a hard reset? Unexpected shutdowns, BSOD/dumps, WHEA hardware errors, storage, resource exhaustion, crashed services and apps, last recorded activity. |
| `diagnostics/Get-LsmDiagnostics.ps1` | Why logons hang on *"Please wait for the Local Session Manager"*. Designed to run **without RDP** (Invoke-Command or an RMM remote shell). |
| `diagnostics/Find-HungServices.ps1` | Which service host process is hung and blocking RDP session creation (uses `sc interrogate`, never stops or starts anything). |
| `diagnostics/Find-StuckSessions.ps1` | Which component freezes logon/logoff and leaves zombie sessions. Run **before** rebooting, since a reboot erases the evidence. |
| `diagnostics/Get-PreRebootChecklist.ps1` | Checklist to capture before a planned reboot (pending operations, services, paths to exclude from scanning for SQL and the ERP). **Its only change:** it enlarges the System and Application event logs so the reboot does not overwrite the evidence. |

## Repairs (change only with an explicit switch)

| Script | What it fixes | Modes |
|---|---|---|
| `repair/Repair-TempProfiles.ps1` | Users logging on with a **temporary profile** (events 1511/1515) after a forced reset, without rebooting the server | `Listar` (default) · `Corrigir` (registry backup first) · `Limpar` |
| `repair/Repair-WindowsSearch.ps1` | Windows Search start/stop loop (7000/7009, DCOM 10005, error 1053) | `Diagnostico` (default) · `Reconstruir` · `Desativar` · `Reverter` |
| `repair/Repair-WindowsServer.ps1` | DISM + SFC while the server stays online, time sync from the domain, SMBv1 **audit** (log only), orphaned scheduled tasks/services, NLA for new RDP connections | `Verificar` · `Reparo` · `Ajustes` · `NLA` · `DesfazerNLA` |
| `repair/Optimize-ServerPerformance.ps1` | Removes disk load a production server does not need (telemetry tasks, automatic defrag of a RAID array) | `Verificar` · `Aplicar` · `Desfazer` |

None of them reboot the server. Application services (ERP, SQL Server) are never touched.

## Tools

| Script | Purpose |
|---|---|
| `tools/Sign-Files.ps1` | Signs internal apps and scripts (`.exe`, `.dll`, `.msi`, `.ps1`...) with a code-signing certificate from the company's internal CA, with timestamping and a final validity check. |

## Usage

```powershell
# PowerShell as Administrator
powershell -ExecutionPolicy Bypass -File .\diagnostics\Invoke-ServerCheckup.ps1
powershell -ExecutionPolicy Bypass -File .\repair\Repair-TempProfiles.ps1              # list only
powershell -ExecutionPolicy Bypass -File .\repair\Repair-TempProfiles.ps1 -Modo Corrigir

# Remote, without RDP
Invoke-Command -ComputerName SERVIDOR01 -FilePath .\diagnostics\Get-LsmDiagnostics.ps1 -Credential DOMINIO\admin
```

Every script has comment-based help: `Get-Help .\repair\Repair-WindowsSearch.ps1 -Full`.

Requirements: Windows Server 2016+ / Windows PowerShell 5.1. The files are UTF-8 with BOM, so Windows PowerShell 5.1 reads the accents correctly.

## Tech

Windows PowerShell 5.1 · CIM/WMI · Event Log · Performance Counters · Remote Desktop Services · SQL Server (sqlcmd) · DISM/SFC · Authenticode

---

## Resumo em português

Scripts PowerShell criados para manter um servidor Windows de produção (ERP TOTVS Protheus + SQL Server + RDP):

- **Diagnóstico somente leitura:** checkup completo com alertas, travamento pós-reset, Local Session Manager, serviços presos, sessões zumbis e checklist pré-reboot.
- **Reparos com modo explícito, backup e desfazer:** perfis temporários, Windows Search, DISM/SFC com o servidor ligado e ajustes de desempenho.
- **Ferramenta de assinatura de código** para apps internos.

Nenhum script reinicia o servidor ou mexe nos serviços do ERP e do SQL. Esta é uma versão genérica, sem dados da empresa.

## License

[MIT](LICENSE)
