<#
.SYNOPSIS
  BoutiqueOS Phase 15B-0 - stock count cost-bridge races (two real psql sessions + sequential stale checks).
  Run AFTER .\scripts\db_fresh.ps1 (Plain mode; DB must contain migrations + seed).
  Commits data into the test DB; re-run db_fresh.ps1 afterwards for a clean state.

.EXPECTED
  A) two managers post the same count (entered cost 120): A holds 3 s, B blocks then ALREADY_POSTED;
     one movement, pool 3/360, cost row applied. D) a retry is ALREADY_POSTED.
  B) cost changed after review -> STALE_REVIEW; a client holding an older hash -> STALE_REVIEW.
  C) ledger moved after review -> STALE_COUNT; re-review posts exactly once.
  Exit 0 on PASS, 1 on FAIL.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = "Continue"
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
$env:PGCLIENTENCODING = "UTF8"
$conn = "postgresql://${PGUSER}@${PGHOST}:${PGPORT}/${PGDB}"
$dir  = Join-Path $Root "tests\concurrency"
$res  = Join-Path $Root "tests\results"
New-Item -ItemType Directory -Force $res | Out-Null
$logA = Join-Path $res "concurrency_count_cost_A.log"; $logB = Join-Path $res "concurrency_count_cost_B.log"

Write-Host "`n==> setup (variant without cost basis, count with entered cost, reviewed)" -ForegroundColor Cyan
& psql $conn -X -v ON_ERROR_STOP=1 -f (Join-Path $dir "110_count_cost_setup.sql")
if($LASTEXITCODE -ne 0){ Write-Host "[FAIL] setup failed" -ForegroundColor Red; exit 1 }

Write-Host "`n==> A/D: session A (holds lock 3 s)" -ForegroundColor Cyan
$procA = Start-Process -FilePath "psql" -ArgumentList @($conn, "-X", "-f", (Join-Path $dir "111_count_cost_post_a.sql")) `
          -RedirectStandardOutput $logA -RedirectStandardError ($logA + ".err") -PassThru -NoNewWindow
Start-Sleep -Seconds 1
Write-Host "==> A/D: session B (must block, then fail)" -ForegroundColor Cyan
$outB = & psql $conn -X -f (Join-Path $dir "112_count_cost_post_b.sql") 2>&1
$outB | Set-Content $logB
$procA.WaitForExit()
$outA = (Get-Content $logA) + (Get-Content ($logA + ".err") -ErrorAction SilentlyContinue)
Write-Host "`n--- A ---"; $outA | ForEach-Object { Write-Host "    $_" }
Write-Host "`n--- B ---"; $outB | ForEach-Object { Write-Host "    $_" }

Write-Host "`n==> verify A/D" -ForegroundColor Cyan
$outV = & psql $conn -X -f (Join-Path $dir "113_count_cost_verify.sql") 2>&1
$outV | ForEach-Object { Write-Host "    $_" }

Write-Host "`n==> B/C: stale review and stale ledger" -ForegroundColor Cyan
$outS = & psql $conn -X -f (Join-Path $dir "114_count_cost_stale.sql") 2>&1
$outS | ForEach-Object { Write-Host "    $_" }

$bFailedRight = ($outB | Select-String 'ALREADY_POSTED').Count -gt 0
$aOk          = ($outA | Select-String 'COMMIT done').Count -gt 0
$verifyOk     = ($outV | Select-String '\[PASS\]').Count -gt 0
$staleOk      = ($outS | Select-String '\[PASS\]').Count -gt 0
if($aOk -and $bFailedRight -and $verifyOk -and $staleOk){ Write-Host "`n[PASS] cost bridge: double-post once, retry refused, cost change and ledger move both stale" -ForegroundColor Green; exit 0 }
Write-Host "`n[FAIL] cost bridge: A_ok=$aOk B_already_posted=$bFailedRight verify=$verifyOk stale=$staleOk" -ForegroundColor Red
exit 1
