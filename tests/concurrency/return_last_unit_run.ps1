<#
.SYNOPSIS
  BoutiqueOS Phase 9B - two terminals exchange the same (only) sold unit: exactly one return.
  Run AFTER .\scripts\db_fresh.ps1 (Plain mode; DB must contain migrations + seed).
  Commits data into the test DB; re-run db_fresh.ps1 afterwards for a clean state.

.EXPECTED
  A posts the exchange and holds its transaction 3 s. B starts 1 s later with a different
  client_transaction_id, blocks on the sale_item row lock, and after A commits fails with OVER_RETURN.
  Verify: exactly 1 return / return_item / movement / replacement sale. Exit 0 on PASS, 1 on FAIL.
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
$logA = Join-Path $res "ret_race_A.log"; $logB = Join-Path $res "ret_race_B.log"

Write-Host "`n==> setup (1 unit sold, replacement stock 2, open register)" -ForegroundColor Cyan
& psql $conn -X -v ON_ERROR_STOP=1 -f (Join-Path $dir "00_setup.sql")
if($LASTEXITCODE -ne 0){ Write-Host "[FAIL] setup failed" -ForegroundColor Red; exit 1 }
& psql $conn -X -v ON_ERROR_STOP=1 -f (Join-Path $dir "40_return_setup.sql")
if($LASTEXITCODE -ne 0){ Write-Host "[FAIL] return setup failed" -ForegroundColor Red; exit 1 }

Write-Host "`n==> session A (holds lock 3 s)" -ForegroundColor Cyan
$procA = Start-Process -FilePath "psql" -ArgumentList @($conn, "-X", "-f", (Join-Path $dir "41_return_a.sql")) `
          -RedirectStandardOutput $logA -RedirectStandardError ($logA + ".err") -PassThru -NoNewWindow
Start-Sleep -Seconds 1
Write-Host "==> session B (different client_transaction_id; must wait, then OVER_RETURN)" -ForegroundColor Cyan
$outB = & psql $conn -X -f (Join-Path $dir "42_return_b.sql") 2>&1
$outB | Set-Content $logB
$procA.WaitForExit()
$outA = (Get-Content $logA) + (Get-Content ($logA + ".err") -ErrorAction SilentlyContinue)

Write-Host "`n--- A ---"; $outA | ForEach-Object { Write-Host "    $_" }
Write-Host "`n--- B ---"; $outB | ForEach-Object { Write-Host "    $_" }

Write-Host "`n==> verify" -ForegroundColor Cyan
$outV = & psql $conn -X -f (Join-Path $dir "44_return_verify.sql") 2>&1
$outV | ForEach-Object { Write-Host "    $_" }

$bFailedRight = ($outB | Select-String 'OVER_RETURN').Count -gt 0
$aOk          = ($outA | Select-String 'COMMIT done').Count -gt 0
$verifyOk     = ($outV | Select-String '\[PASS\]').Count -gt 0
if($aOk -and $bFailedRight -and $verifyOk){ Write-Host "`n[PASS] return last unit: A exchanged, B got OVER_RETURN, exactly one return" -ForegroundColor Green; exit 0 }
Write-Host "`n[FAIL] return last unit: A_ok=$aOk B_right=$bFailedRight verify=$verifyOk" -ForegroundColor Red
exit 1
