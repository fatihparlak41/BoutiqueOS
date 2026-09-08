<#
.SYNOPSIS
  BoutiqueOS Rev 3 - applies harness + migrations + seed + verification tests to a FRESH database.

.MODES
  -Init            : create + start the local PostgreSQL cluster under .pgdata (once). Idempotent.
  (default, Plain) : DROP/CREATE $PGDATABASE on the local cluster, then
                     tests\000_test_harness.sql -> supabase\migrations\*.sql (name order) -> seeds\*.sql -> tests\005_verification_tests.sql
  -Mode Supabase   : Supabase LOCAL stack (Docker). Requires `docker` + `supabase start`. Harness is skipped (real auth schema).
                     Migrations are applied by `supabase db reset --local`; seed + tests via psql on 54322.
                     NOTE: this mode NEVER touches the remote project. No `db push` anywhere in this script.
  -NoTests         : skip 005
  -Stop            : stop the local cluster

.EXIT CODE
  0 = every step applied and 005 reported 0 failures
  1 = migration/seed error, or at least one [FAIL], or verification aborted
#>
[CmdletBinding()]
param(
  [ValidateSet("Plain","Supabase")] [string]$Mode = "Plain",
  [switch]$Init,
  [switch]$Stop,
  [switch]$NoTests
)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
function Step($m){ Write-Host "`n==> $m" -ForegroundColor Cyan }
function Ok($m){ Write-Host "    [OK] $m" -ForegroundColor Green }
function Fail($m){ Write-Host "    [FAIL] $m" -ForegroundColor Red }
# psql writes NOTICE/WARNING to stderr; under $ErrorActionPreference=Stop PS 5.1 would turn that into a
# terminating NativeCommandError. Native calls run with 'Continue' and are judged by $LASTEXITCODE only.
function Invoke-Native([scriptblock]$sb){
  $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
  try { $o = @(& $sb 2>&1 | ForEach-Object { if($_ -is [System.Management.Automation.ErrorRecord]){ $_.Exception.Message } else { "$_" } }) }
  finally { $ErrorActionPreference = $prev }
  return $o
}

# ---- .env
if(Test-Path ".env"){
  Get-Content ".env" | Where-Object { $_ -match '^\s*[^#].*=' } | ForEach-Object {
    $k,$v = $_ -split '=',2; [Environment]::SetEnvironmentVariable($k.Trim(), $v.Trim(), "Process")
  }
}
function Def($v,$d){ if([string]::IsNullOrWhiteSpace($v)){ $d } else { $v } }
$PGHOST = Def $env:PGHOST     "localhost"
$PGPORT = Def $env:PGPORT     "5433"
$PGUSER = Def $env:PGUSER     "postgres"
$PGDB   = Def $env:PGDATABASE "boutiqueos_test"
$env:PGPASSWORD = Def $env:PGPASSWORD "postgres"
$env:PGCLIENTENCODING = "UTF8"   # SQL files are UTF-8 (Turkish text); do not depend on the console code page
$pgdata = Join-Path $Root ".pgdata"
$resDir = Join-Path $Root "tests\results"
$log    = Join-Path $resDir "last_run.log"
New-Item -ItemType Directory -Force $resDir | Out-Null

if($Mode -eq "Plain"){
  foreach($c in "psql","initdb","pg_ctl"){ if(-not (Get-Command $c -ErrorAction SilentlyContinue)){ throw "$c not found - run bootstrap.ps1 (scoop install postgresql)" } }
} else {
  foreach($c in "psql","supabase","docker"){ if(-not (Get-Command $c -ErrorAction SilentlyContinue)){ throw "$c not found. -Mode Supabase needs Docker Desktop + Supabase CLI. Use Plain mode until Docker is installed." } }
}

# ---- local cluster
if($Stop){ pg_ctl -D $pgdata stop -m fast; exit 0 }

if($Init){
  Step "Local PostgreSQL cluster: $pgdata (port $PGPORT)"
  if(-not (Test-Path $pgdata)){
    $pwFile = Join-Path $env:TEMP "boutiqueos_pw.txt"
    [IO.File]::WriteAllText($pwFile, $env:PGPASSWORD)
    & initdb -D $pgdata -U $PGUSER --auth=scram-sha-256 "--pwfile=$pwFile" -E UTF8 --locale=C
    if($LASTEXITCODE -ne 0){ throw "initdb failed" }
    Remove-Item $pwFile -Force
    Add-Content (Join-Path $pgdata "postgresql.conf") "`nport = $PGPORT`nlisten_addresses = 'localhost'`npassword_encryption = 'scram-sha-256'`n"
    Ok "initdb done"
  }
  Invoke-Native { pg_ctl -D $pgdata status } | Out-Null
  if($LASTEXITCODE -eq 0){ Ok "cluster already running" }
  else {
    Invoke-Native { pg_ctl -D $pgdata -l (Join-Path $pgdata "server.log") -w start } | Out-Null
    if($LASTEXITCODE -ne 0){ throw "pg_ctl start failed - see .pgdata\server.log" }
    Ok "cluster started"
  }
  exit 0
}

# ---- migration naming guard (no short-number + timestamp mix)
$migs = Get-ChildItem "supabase\migrations\*.sql" | Sort-Object Name
if($migs.Count -eq 0){ throw "no migrations found under supabase\migrations" }
$short = @($migs | Where-Object { $_.Name -match '^\d{1,4}_' })
$stamp = @($migs | Where-Object { $_.Name -match '^\d{14}_' })
if($short.Count -gt 0 -and $stamp.Count -gt 0){
  throw "Mixed migration naming (short: $($short.Count), timestamp: $($stamp.Count)). Delete the old 00N_*.sql files before running."
}

# ---- connections
if($Mode -eq "Supabase"){
  $connDb   = "postgresql://postgres:postgres@localhost:54322/postgres"
} else {
  $connBase = "postgresql://${PGUSER}@${PGHOST}:${PGPORT}/postgres"
  $connDb   = "postgresql://${PGUSER}@${PGHOST}:${PGPORT}/${PGDB}"
}

function Run-Sql([string]$conn,[string]$file){
  Write-Host "    -> $file"
  $out = Invoke-Native { psql $conn -X -v ON_ERROR_STOP=1 -f $file }
  $out | Add-Content $log
  if($LASTEXITCODE -ne 0){ $out | Select-Object -Last 20 | ForEach-Object { Fail $_ }; throw "ERROR in $file" }
  $out | Select-String 'NOTICE:' | ForEach-Object { Write-Host "       $($_.Line -replace '^psql:[^:]+:\d+:\s*','')" -ForegroundColor DarkGray }
}

"# BoutiqueOS fresh apply - $(Get-Date -Format s) - mode=$Mode" | Set-Content $log

# ---- 1. fresh DB
Step "Fresh database ($Mode)"
if($Mode -eq "Plain"){
  Invoke-Native { pg_ctl -D $pgdata status } | Out-Null
  if($LASTEXITCODE -ne 0){ throw "local cluster is not running - run: .\scripts\db_fresh.ps1 -Init" }
  Invoke-Native { psql $connBase -X -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS $PGDB WITH (FORCE);" } | Out-Null
  if($LASTEXITCODE -ne 0){ throw "DROP DATABASE failed" }
  Invoke-Native { psql $connBase -X -v ON_ERROR_STOP=1 -c "CREATE DATABASE $PGDB;" } | Out-Null
  if($LASTEXITCODE -ne 0){ throw "CREATE DATABASE failed" }
  Ok "$PGDB recreated"
} else {
  Invoke-Native { docker info } | Out-Null
  if($LASTEXITCODE -ne 0){ throw "Docker is not running. Start Docker Desktop, then: supabase start" }
  Invoke-Native { supabase db reset --local } | Tee-Object -FilePath $log -Append
  if($LASTEXITCODE -ne 0){ throw "supabase db reset --local failed (is the local stack up? run: supabase start)" }
  Ok "supabase db reset --local (migrations applied by CLI)"
}

# ---- 2. harness (Plain only)
if($Mode -eq "Plain"){
  Step "Test harness (Supabase shim)"
  Run-Sql $connDb "tests\000_test_harness.sql"
  Step "Migrations ($($migs.Count))"
  foreach($m in $migs){ Run-Sql $connDb $m.FullName }
}

# ---- 3. seeds
Step "Seeds"
Get-ChildItem "seeds\*.sql" | Sort-Object Name | ForEach-Object { Run-Sql $connDb $_.FullName }

# ---- 4. verification tests (file owns its BEGIN ... ROLLBACK; raises on any FAIL)
if(-not $NoTests){
  Step "Verification tests"
  $tfile = "tests\005_verification_tests.sql"
  $out = Invoke-Native { psql $connDb -X -f $tfile }
  $out | Add-Content $log
  $tcode = $LASTEXITCODE
  $pass = ($out | Select-String '\[PASS\]').Count
  $fail = ($out | Select-String '\[FAIL\]').Count
  $errs = ($out | Select-String '^psql:.*ERROR:|^ERROR:').Count
  $out | Select-String '\[FAIL\]|ERROR:' | ForEach-Object { Fail $_.Line }
  $out | Select-String 'verification:' | ForEach-Object { Write-Host "    $($_.Line)" }
  $color = if($fail -eq 0 -and $tcode -eq 0){ "Green" } else { "Red" }
  Write-Host "`n    PASS: $pass   FAIL: $fail   psql errors: $errs   exit: $tcode" -ForegroundColor $color
  Write-Host "    log: $log"
  if($fail -gt 0 -or $tcode -ne 0){ exit 1 }
}
Ok "done ($Mode)"
exit 0
