<#
.SYNOPSIS
  BoutiqueOS Phase 13A - SaaS platform races: two platform admins approve the same application, one applicant submits twice.
  Run AFTER .\scripts\db_fresh.ps1 (Plain mode; DB must contain migrations + seed).
  Commits data into the test DB; re-run db_fresh.ps1 afterwards for a clean state.

.EXPECTED
  A approves application X and submits for applicant Y, then holds its transaction 3 s. B starts 1 s later,
  blocks on the application row lock / the one-pending-per-applicant index, and after A commits REPLAYS both
  (no error, no second tenant, no second application). Verify: one business, one owner, one subscription,
  one audit row, one application for Y. Exit 0 on PASS, 1 on FAIL.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = "Continue"   # psql NOTICEs are stderr; judge by exit codes
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $Root
if(Test-Path ".env"){
  Get-Content ".env" | Where-Object { $_ -match '^\s*[^#].*=' } | ForEach-Object {
    $k,$v = $_ -split '=',2; [Environment]::SetEnvironmentVariable($k.Trim(), $v.Trim(), "Process")
  }
}
function Def($v,$d){ if([string]::IsNullOrWhiteSpace($v)){ $d } else { $v } }
$PGHOST = Def $env:PGHOST "localhost"; $PGPORT = Def $env:PGPORT "5433"
$PGUSER = Def $env:PGUSER "postgres";  $PGDB   = Def $env:PGDATABASE "boutiqueos_test"
$env:PGPASSWORD = Def $env:PGPASSWORD "postgres"
$env:PGCLIENTENCODING = "UTF8"   # SQL files are UTF-8 (Turkish text); do not depend on the console code page
$conn = "postgresql://${PGUSER}@${PGHOST}:${PGPORT}/${PGDB}"
$dir  = Join-Path $Root "tests\concurrency"
$res  = Join-Path $Root "tests\results"
New-Item -ItemType Directory -Force $res | Out-Null
$logA = Join-Path $res "concurrency_saas_A.log"; $logB = Join-Path $res "concurrency_saas_B.log"

Write-Host "`n==> setup (two platform admins, applicant X pending, applicant Y)" -ForegroundColor Cyan
& psql $conn -X -v ON_ERROR_STOP=1 -f (Join-Path $dir "80_saas_setup.sql")
if($LASTEXITCODE -ne 0){ Write-Host "[FAIL] setup failed" -ForegroundColor Red; exit 1 }

Write-Host "`n==> session A (holds lock 3 s)" -ForegroundColor Cyan
$procA = Start-Process -FilePath "psql" -ArgumentList @($conn, "-X", "-f", (Join-Path $dir "81_saas_a.sql")) `
          -RedirectStandardOutput $logA -RedirectStandardError ($logA + ".err") -PassThru -NoNewWindow
Start-Sleep -Seconds 1
Write-Host "==> session B (must block, then replay)" -ForegroundColor Cyan
$outB = & psql $conn -X -f (Join-Path $dir "82_saas_b.sql") 2>&1
$outB | Set-Content $logB
$procA.WaitForExit()
$outA = (Get-Content $logA) + (Get-Content ($logA + ".err") -ErrorAction SilentlyContinue)

Write-Host "`n--- A ---"; $outA | ForEach-Object { Write-Host "    $_" }
Write-Host "`n--- B ---"; $outB | ForEach-Object { Write-Host "    $_" }

Write-Host "`n==> verify" -ForegroundColor Cyan
$outV = & psql $conn -X -f (Join-Path $dir "83_saas_verify.sql") 2>&1
$outV | ForEach-Object { Write-Host "    $_" }

$bRight   = (($outB | Select-String 'B_APPROVE_REPLAYED=true').Count -gt 0) -and (($outB | Select-String 'B_SUBMIT_REPLAYED=true').Count -gt 0) -and (($outB | Select-String 'ERROR').Count -eq 0) -and (($outB | Select-String 'COMMIT done').Count -gt 0)
$aOk      = (($outA | Select-String 'COMMIT done').Count -gt 0) -and (($outA | Select-String 'ERROR').Count -eq 0)
$verifyOk = ($outV | Select-String '\[PASS\]').Count -gt 0
if($aOk -and $bRight -and $verifyOk){ Write-Host "`n[PASS] saas races: A approved + submitted once, B replayed both, one tenant" -ForegroundColor Green; exit 0 }
Write-Host "`n[FAIL] saas races: A_ok=$aOk B_right=$bRight verify=$verifyOk" -ForegroundColor Red
exit 1
