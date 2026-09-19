<#
.SYNOPSIS
  BoutiqueOS Phase 13B - SaaS billing races (manual billing): double invoice issue, double payment reference,
  plan price change concurrent with a renewal issue.
  Run AFTER .\scripts\db_fresh.ps1 (Plain mode; DB must contain migrations + seed).
  Commits data into the test DB; re-run db_fresh.ps1 afterwards for a clean state.

.EXPECTED
  Phase 1  A1 issues the first invoice and holds 3 s; B1 (1 s later) blocks on the subscription row and REPLAYS the open invoice.
  Phase 2  A2 records the full payment with reference RACE-REF and holds 3 s; B2 records "race-ref" on the same invoice,
           blocks, then REPLAYS (one payment, one activation).
  Phase 3  A3 issues the renewal and holds 3 s; B3 changes the catalogue price meanwhile (not blocked).
  Verify   2 invoices (1 paid at the old price, 1 open whose subtotal equals its item line and is one of old/new price),
           1 payment, subscription active, exactly one activation audit row. Exit 0 on PASS, 1 on FAIL.
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
$env:PGCLIENTENCODING = "UTF8"
$conn = "postgresql://${PGUSER}@${PGHOST}:${PGPORT}/${PGDB}"
$dir  = Join-Path $Root "tests\concurrency"
$res  = Join-Path $Root "tests\results"
New-Item -ItemType Directory -Force $res | Out-Null

function Run-Pair($n, $aFile, $bFile, $bMarker){
  $logA = Join-Path $res "concurrency_billing_${n}_A.log"; $logB = Join-Path $res "concurrency_billing_${n}_B.log"
  Write-Host "`n==> phase $n : session A (holds 3 s)" -ForegroundColor Cyan
  $procA = Start-Process -FilePath "psql" -ArgumentList @($conn, "-X", "-f", (Join-Path $dir $aFile)) `
            -RedirectStandardOutput $logA -RedirectStandardError ($logA + ".err") -PassThru -NoNewWindow
  Start-Sleep -Seconds 1
  Write-Host "==> phase $n : session B" -ForegroundColor Cyan
  $outB = & psql $conn -X -f (Join-Path $dir $bFile) 2>&1
  $outB | Set-Content $logB
  $procA.WaitForExit()
  $outA = (Get-Content $logA) + (Get-Content ($logA + ".err") -ErrorAction SilentlyContinue)
  Write-Host "`n--- A$n ---"; $outA | ForEach-Object { Write-Host "    $_" }
  Write-Host "`n--- B$n ---"; $outB | ForEach-Object { Write-Host "    $_" }
  $aOk = (($outA | Select-String 'COMMIT done').Count -gt 0) -and (($outA | Select-String 'ERROR').Count -eq 0)
  $bOk = (($outB | Select-String $bMarker).Count -gt 0) -and (($outB | Select-String 'ERROR').Count -eq 0) -and (($outB | Select-String 'COMMIT done').Count -gt 0)
  return ($aOk -and $bOk)
}

Write-Host "`n==> setup (two platform admins, applicant Z approved, pending subscription)" -ForegroundColor Cyan
& psql $conn -X -v ON_ERROR_STOP=1 -f (Join-Path $dir "90_billing_setup.sql")
if($LASTEXITCODE -ne 0){ Write-Host "[FAIL] setup failed" -ForegroundColor Red; exit 1 }

$p1 = Run-Pair 1 "91_billing_a1.sql" "92_billing_b1.sql" 'B1_ISSUE_REPLAYED=true'
# capture the open invoice id for phase 2
& psql $conn -X -v ON_ERROR_STOP=1 -c "INSERT INTO zz_bill_ctx SELECT 'inv_z', id::text FROM saas_invoices WHERE subscription_id = (SELECT v::uuid FROM zz_bill_ctx WHERE k = 'sub_z') AND status = 'open' ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;" | Out-Null
$p2 = Run-Pair 2 "93_billing_a2.sql" "94_billing_b2.sql" 'B2_PAY_REPLAYED=true'
$p3 = Run-Pair 3 "95_billing_a3.sql" "96_billing_b3.sql" 'B3_PRICE_CHANGED=true'

Write-Host "`n==> verify" -ForegroundColor Cyan
$outV = & psql $conn -X -f (Join-Path $dir "97_billing_verify.sql") 2>&1
$outV | ForEach-Object { Write-Host "    $_" }
$verifyOk = ($outV | Select-String '\[PASS\]').Count -gt 0

if($p1 -and $p2 -and $p3 -and $verifyOk){ Write-Host "`n[PASS] billing races: one invoice per period, one payment per reference, one activation, deterministic snapshot" -ForegroundColor Green; exit 0 }
Write-Host "`n[FAIL] billing races: phase1=$p1 phase2=$p2 phase3=$p3 verify=$verifyOk" -ForegroundColor Red
exit 1
