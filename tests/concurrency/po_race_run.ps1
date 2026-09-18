<#
.SYNOPSIS
  BoutiqueOS Phase 12A - purchase order races: double approve, two receipts posting the last units, duplicate action, numbering.
  Run AFTER .\scripts\db_fresh.ps1 (Plain mode; DB must contain migrations + seed).
  Commits data into the test DB; re-run db_fresh.ps1 afterwards for a clean state.

.EXPECTED
  A posts the goods receipt and holds its transaction 3 s. B starts 1 s later, blocks on
  the goods_receipts header row lock, and after A commits fails with INVALID_STATE.
  Verify: receipt posted once, one movement, one liability. Exit 0 on PASS, 1 on FAIL.
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
$logA = Join-Path $res "concurrency_po_A.log"; $logB = Join-Path $res "concurrency_po_B.log"

Write-Host "`n==> setup (draft / ordered / approved POs, two competing receipts)" -ForegroundColor Cyan
& psql $conn -X -v ON_ERROR_STOP=1 -f (Join-Path $dir "70_po_setup.sql")
if($LASTEXITCODE -ne 0){ Write-Host "[FAIL] setup failed" -ForegroundColor Red; exit 1 }

Write-Host "`n==> session A (holds lock 3 s)" -ForegroundColor Cyan
$procA = Start-Process -FilePath "psql" -ArgumentList @($conn, "-X", "-f", (Join-Path $dir "71_po_a.sql")) `
          -RedirectStandardOutput $logA -RedirectStandardError ($logA + ".err") -PassThru -NoNewWindow
Start-Sleep -Seconds 1
Write-Host "==> session B (must block, then fail)" -ForegroundColor Cyan
$outB = & psql $conn -X -f (Join-Path $dir "72_po_b.sql") 2>&1
$outB | Set-Content $logB
$procA.WaitForExit()
$outA = (Get-Content $logA) + (Get-Content ($logA + ".err") -ErrorAction SilentlyContinue)

Write-Host "`n--- A ---"; $outA | ForEach-Object { Write-Host "    $_" }
Write-Host "`n--- B ---"; $outB | ForEach-Object { Write-Host "    $_" }

Write-Host "`n==> verify" -ForegroundColor Cyan
$outV = & psql $conn -X -f (Join-Path $dir "73_po_verify.sql") 2>&1
$outV | ForEach-Object { Write-Host "    $_" }

$bFailedRight = (($outB | Select-String 'ERROR:  INVALID_STATE').Count -ge 2) -and (($outB | Select-String 'ERROR:  OVER_RECEIPT').Count -gt 0) -and (($outB | Select-String 'COMMIT done').Count -gt 0)
$aOk          = ($outA | Select-String 'COMMIT done').Count -gt 0
$verifyOk     = ($outV | Select-String '\[PASS\]').Count -gt 0
if($aOk -and $bFailedRight -and $verifyOk){ Write-Host "`n[PASS] po races: A approved/posted/ordered/numbered, B got INVALID_STATE x2 + OVER_RECEIPT and the next number" -ForegroundColor Green; exit 0 }
Write-Host "`n[FAIL] po races: A_ok=$aOk B_right=$bFailedRight verify=$verifyOk" -ForegroundColor Red
exit 1
