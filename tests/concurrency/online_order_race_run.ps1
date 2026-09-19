<#
.SYNOPSIS
  BoutiqueOS Phase 14B - online order races: last unit, idempotent key, customer cancel vs merchant confirm,
  POS conversion double-submit, cancel after conversion, price change during checkout.
  Run AFTER .\scripts\db_fresh.ps1 (Plain mode). Commits data; re-run db_fresh.ps1 afterwards.

.EXPECTED
  Phase 1  A1 checks out the LAST unit and holds 3 s; B1 (1 s later) blocks on the same pool/hold locks and is refused
           (INSUFFICIENT), then replays A's key (B1_REPLAYED=true).
  Phase 2  A2 confirms the order and holds; B2 (customer cancel by token) blocks, then CANCEL_NOT_ALLOWED.
  Phase 3  A3 converts the order at the POS and holds; B3 double-submits the same client transaction id and gets a replay,
           then a merchant cancel is INVALID_STATE (completed).
  Phase 4  A4 checks out MANY and holds; B4 changes the catalogue price; the order snapshot is one price, item = total.
  Verify   2 orders, 1 line for the last unit, order A completed, exactly 1 sale, price snapshot consistent. Exit 0 on PASS.
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

function Run-Pair($n, $aFile, $bFile, $bMarker, $bErr){
  $logA = Join-Path $res "concurrency_order_${n}_A.log"; $logB = Join-Path $res "concurrency_order_${n}_B.log"
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
  $bOk = (($outB | Select-String $bMarker).Count -gt 0)
  if($bErr){ $bOk = $bOk -and (($outB | Select-String $bErr).Count -gt 0) }
  return ($aOk -and $bOk)
}

Write-Host "`n==> setup (business Z, storefront zz-race, LAST=1 / MANY=20, open register)" -ForegroundColor Cyan
& psql $conn -X -v ON_ERROR_STOP=1 -f (Join-Path $dir "100_order_setup.sql")
if($LASTEXITCODE -ne 0){ Write-Host "[FAIL] setup failed" -ForegroundColor Red; exit 1 }

$p1 = Run-Pair 1 "101_order_a1.sql" "102_order_b1.sql" 'B1_REPLAYED=true' 'INSUFFICIENT'
# capture order A and its token for the later phases
& psql $conn -X -v ON_ERROR_STOP=1 -c "INSERT INTO zz_ord_ctx SELECT 'o1', id::text FROM storefront_orders WHERE business_id = (SELECT v::uuid FROM zz_ord_ctx WHERE k = 'biz') AND customer_name = 'Race A' ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v; INSERT INTO zz_ord_ctx SELECT 'tok1', encode(sha256(convert_to('token:' || repeat('a', 64) || ':' || (SELECT v FROM zz_ord_ctx WHERE k = 'sf'), 'UTF8')), 'hex') ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;" | Out-Null
$p2 = Run-Pair 2 "103_order_a2.sql" "104_order_b2.sql" 'CANCEL_NOT_ALLOWED' $null
$p3 = Run-Pair 3 "105_order_a3.sql" "106_order_b3.sql" 'B3_REPLAYED=true' 'INVALID_STATE'
$p4 = Run-Pair 4 "107_order_a4.sql" "108_order_b4.sql" 'PRICE_CHANGED=true' $null

Write-Host "`n==> verify" -ForegroundColor Cyan
$outV = & psql $conn -X -f (Join-Path $dir "109_order_verify.sql") 2>&1
$outV | ForEach-Object { Write-Host "    $_" }
$verifyOk = ($outV | Select-String '\[PASS\]').Count -gt 0

if($p1 -and $p2 -and $p3 -and $p4 -and $verifyOk){ Write-Host "`n[PASS] order races: last unit once, key replayed, confirm beat cancel, one sale on double-submit, no cancel after conversion, deterministic price snapshot" -ForegroundColor Green; exit 0 }
Write-Host "`n[FAIL] order races: phase1=$p1 phase2=$p2 phase3=$p3 phase4=$p4 verify=$verifyOk" -ForegroundColor Red
exit 1
