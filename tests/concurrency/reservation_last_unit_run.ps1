<#
.SYNOPSIS
  BoutiqueOS Phase 10A - two users reserve the last available unit: exactly one hold.
  Run AFTER .\scripts\db_fresh.ps1 (Plain mode; DB must contain migrations + seed).
  Commits data into the test DB; re-run db_fresh.ps1 afterwards for a clean state.

.EXPECTED
  A creates the reservation and holds its transaction 3 s. B starts 1 s later, blocks on the
  variant_cost_pools row lock, and after A commits fails with INSUFFICIENT_AVAILABLE_STOCK.
  Verify: exactly 1 active hold, available 0, no inventory movement. Exit 0 on PASS, 1 on FAIL.
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
$logA = Join-Path $res "res_race_A.log"; $logB = Join-Path $res "res_race_B.log"

Write-Host "`n==> setup (1 available unit, one synthetic customer)" -ForegroundColor Cyan
& psql $conn -X -v ON_ERROR_STOP=1 -f (Join-Path $dir "00_setup.sql")
if($LASTEXITCODE -ne 0){ Write-Host "[FAIL] setup failed" -ForegroundColor Red; exit 1 }
& psql $conn -X -v ON_ERROR_STOP=1 -f (Join-Path $dir "60_res_setup.sql")
if($LASTEXITCODE -ne 0){ Write-Host "[FAIL] reservation setup failed" -ForegroundColor Red; exit 1 }

Write-Host "`n==> session A (holds lock 3 s)" -ForegroundColor Cyan
$procA = Start-Process -FilePath "psql" -ArgumentList @($conn, "-X", "-f", (Join-Path $dir "61_res_a.sql")) `
          -RedirectStandardOutput $logA -RedirectStandardError ($logA + ".err") -PassThru -NoNewWindow
Start-Sleep -Seconds 1
Write-Host "==> session B (second reservation; must wait, then INSUFFICIENT_AVAILABLE_STOCK)" -ForegroundColor Cyan
$outB = & psql $conn -X -f (Join-Path $dir "62_res_b.sql") 2>&1
$outB | Set-Content $logB
$procA.WaitForExit()
$outA = (Get-Content $logA) + (Get-Content ($logA + ".err") -ErrorAction SilentlyContinue)

Write-Host "`n--- A ---"; $outA | ForEach-Object { Write-Host "    $_" }
Write-Host "`n--- B ---"; $outB | ForEach-Object { Write-Host "    $_" }

Write-Host "`n==> verify" -ForegroundColor Cyan
$outV = & psql $conn -X -f (Join-Path $dir "64_res_verify.sql") 2>&1
$outV | ForEach-Object { Write-Host "    $_" }

$bFailedRight = ($outB | Select-String 'INSUFFICIENT_AVAILABLE_STOCK').Count -gt 0
$aOk          = ($outA | Select-String 'COMMIT done').Count -gt 0
$verifyOk     = ($outV | Select-String '\[PASS\]').Count -gt 0
if($aOk -and $bFailedRight -and $verifyOk){ Write-Host "`n[PASS] reservation last unit: A held, B got INSUFFICIENT_AVAILABLE_STOCK, exactly one hold" -ForegroundColor Green; exit 0 }
Write-Host "`n[FAIL] reservation last unit: A_ok=$aOk B_right=$bFailedRight verify=$verifyOk" -ForegroundColor Red
exit 1
