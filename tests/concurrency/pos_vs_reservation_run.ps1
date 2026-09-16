<#
.SYNOPSIS
  BoutiqueOS Phase 10A - a POS sale and a reservation race for the last unit: the sale wins, the hold is refused.
  Run AFTER .\scripts\db_fresh.ps1 (Plain mode; DB must contain migrations + seed).
  Commits data into the test DB; re-run db_fresh.ps1 afterwards for a clean state.

.EXPECTED
  A (POS) sells the last unit and holds its transaction 3 s. B starts 1 s later with a reservation
  for the same unit, blocks on the variant_cost_pools row lock, and after A commits fails with
  INSUFFICIENT_AVAILABLE_STOCK. Verify: 1 sale, 0 holds, on_hand 0. Exit 0 on PASS, 1 on FAIL.
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
$logA = Join-Path $res "pos_res_A.log"; $logB = Join-Path $res "pos_res_B.log"

Write-Host "`n==> setup (1 available unit, one synthetic customer)" -ForegroundColor Cyan
& psql $conn -X -v ON_ERROR_STOP=1 -f (Join-Path $dir "00_setup.sql")
if($LASTEXITCODE -ne 0){ Write-Host "[FAIL] setup failed" -ForegroundColor Red; exit 1 }
& psql $conn -X -v ON_ERROR_STOP=1 -f (Join-Path $dir "60_res_setup.sql")
if($LASTEXITCODE -ne 0){ Write-Host "[FAIL] reservation setup failed" -ForegroundColor Red; exit 1 }

Write-Host "`n==> session A (holds lock 3 s)" -ForegroundColor Cyan
$procA = Start-Process -FilePath "psql" -ArgumentList @($conn, "-X", "-f", (Join-Path $dir "31_pos_sale_a.sql")) `
          -RedirectStandardOutput $logA -RedirectStandardError ($logA + ".err") -PassThru -NoNewWindow
Start-Sleep -Seconds 1
Write-Host "==> session B (reservation while the POS sale is open; must wait, then INSUFFICIENT_AVAILABLE_STOCK)" -ForegroundColor Cyan
$outB = & psql $conn -X -f (Join-Path $dir "63_pos_vs_res_b.sql") 2>&1
$outB | Set-Content $logB
$procA.WaitForExit()
$outA = (Get-Content $logA) + (Get-Content ($logA + ".err") -ErrorAction SilentlyContinue)

Write-Host "`n--- A ---"; $outA | ForEach-Object { Write-Host "    $_" }
Write-Host "`n--- B ---"; $outB | ForEach-Object { Write-Host "    $_" }

Write-Host "`n==> verify" -ForegroundColor Cyan
$outV = & psql $conn -X -f (Join-Path $dir "65_pos_vs_res_verify.sql") 2>&1
$outV | ForEach-Object { Write-Host "    $_" }

$bFailedRight = ($outB | Select-String 'INSUFFICIENT_AVAILABLE_STOCK').Count -gt 0
$aOk          = ($outA | Select-String 'COMMIT done').Count -gt 0
$verifyOk     = ($outV | Select-String '\[PASS\]').Count -gt 0
if($aOk -and $bFailedRight -and $verifyOk){ Write-Host "`n[PASS] pos vs reservation: A sold the last unit, B hold refused, no phantom hold" -ForegroundColor Green; exit 0 }
Write-Host "`n[FAIL] pos vs reservation: A_ok=$aOk B_right=$bFailedRight verify=$verifyOk" -ForegroundColor Red
exit 1
