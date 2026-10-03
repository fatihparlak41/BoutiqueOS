<#
.SYNOPSIS
  BoutiqueOS product status audit - two managers archive the same product at once (two real psql sessions).
  Run AFTER .\scripts\db_fresh.ps1 (Plain mode; DB must contain migrations + seed).
  Commits data into the test DB; re-run db_fresh.ps1 afterwards for a clean state.

.EXPECTED
  A archives and holds the row lock 3 s; B blocks, then sees 'archived' and returns changed=false.
  The product is archived once and has exactly one product_status_events row (A's reason).
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
$logA = Join-Path $res "concurrency_product_status_A.log"; $logB = Join-Path $res "concurrency_product_status_B.log"

Write-Host "`n==> setup (two managers, one active product)" -ForegroundColor Cyan
& psql $conn -X -v ON_ERROR_STOP=1 -f (Join-Path $dir "120_product_status_setup.sql")
if($LASTEXITCODE -ne 0){ Write-Host "[FAIL] setup failed" -ForegroundColor Red; exit 1 }

Write-Host "`n==> session A (holds lock 3 s)" -ForegroundColor Cyan
$procA = Start-Process -FilePath "psql" -ArgumentList @($conn, "-X", "-f", (Join-Path $dir "121_product_status_a.sql")) `
          -RedirectStandardOutput $logA -RedirectStandardError ($logA + ".err") -PassThru -NoNewWindow
Start-Sleep -Seconds 1
Write-Host "==> session B (must block, then no-op)" -ForegroundColor Cyan
$outB = & psql $conn -X -f (Join-Path $dir "122_product_status_b.sql") 2>&1
$outB | Set-Content $logB
$procA.WaitForExit()
$outA = (Get-Content $logA) + (Get-Content ($logA + ".err") -ErrorAction SilentlyContinue)
Write-Host "`n--- A ---"; $outA | ForEach-Object { Write-Host "    $_" }
Write-Host "`n--- B ---"; $outB | ForEach-Object { Write-Host "    $_" }

Write-Host "`n==> verify" -ForegroundColor Cyan
$outV = & psql $conn -X -f (Join-Path $dir "123_product_status_verify.sql") 2>&1
$outV | ForEach-Object { Write-Host "    $_" }

$aOk      = ($outA | Select-String 'COMMIT done').Count -gt 0
$bNoop    = ($outB | Select-String 'B_RESULT changed=false').Count -gt 0
$verifyOk = ($outV | Select-String '\[PASS\]').Count -gt 0
if($aOk -and $bNoop -and $verifyOk){ Write-Host "`n[PASS] product status: concurrent archive applied once, one audit event" -ForegroundColor Green; exit 0 }
Write-Host "`n[FAIL] product status: A_ok=$aOk B_noop=$bNoop verify=$verifyOk" -ForegroundColor Red
exit 1
