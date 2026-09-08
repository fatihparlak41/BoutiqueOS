<#
.SYNOPSIS
  BoutiqueOS — sıfır veritabanına migration + seed + doğrulama testlerini uygular.

.MODES
  -Init            : .pgdata altında yerel PostgreSQL cluster oluşturur ve başlatır (bir kez)
  (default)        : DB'yi DROP/CREATE eder, tests\000_test_harness.sql -> supabase\migrations\*.sql
                     -> seeds\*.sql -> tests\005_verification_tests.sql sırasıyla uygular
  -Mode Supabase   : Docker'daki Supabase local stack'e uygular (harness ATLANIR; auth şeması gerçek)
  -NoTests         : 005 testlerini çalıştırma
  -Stop            : yerel cluster'ı durdur

.EXIT CODE
  0 = tüm adımlar hatasız ve testlerde [FAIL] yok
  1 = migration/seed hatası veya en az bir [FAIL]
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

# ---- .env yükle
if(Test-Path ".env"){
  Get-Content ".env" | Where-Object { $_ -match '^\s*[^#].*=' } | ForEach-Object {
    $k,$v = $_ -split '=',2; [Environment]::SetEnvironmentVariable($k.Trim(), $v.Trim(), "Process")
  }
}
function Def($v,$d){ if([string]::IsNullOrWhiteSpace($v)){ $d } else { $v } }   # PS 5.1 uyumlu
$PGHOST = Def $env:PGHOST     "localhost"
$PGPORT = Def $env:PGPORT     "5433"
$PGUSER = Def $env:PGUSER     "postgres"
$PGDB   = Def $env:PGDATABASE "boutiqueos_test"
$env:PGPASSWORD = Def $env:PGPASSWORD "postgres"
$pgdata = Join-Path $Root ".pgdata"
$log    = Join-Path $Root "tests\results\last_run.log"
New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null

foreach($c in "psql","initdb","pg_ctl"){ if(-not (Get-Command $c -ErrorAction SilentlyContinue) -and $Mode -eq "Plain"){ throw "$c bulunamadı — bootstrap.ps1 çalıştır (scoop install postgresql)" } }

# ---- yerel cluster yönetimi
if($Stop){ pg_ctl -D $pgdata stop -m fast; exit 0 }

if($Init){
  Step "Yerel PostgreSQL cluster: $pgdata (port $PGPORT)"
  if(-not (Test-Path $pgdata)){
    $pw = New-TemporaryFile; Set-Content $pw $env:PGPASSWORD -NoNewline
    initdb -D $pgdata -U $PGUSER --auth=md5 --pwfile=$pw.FullName -E UTF8 --locale=C | Out-Null
    Remove-Item $pw
    Add-Content (Join-Path $pgdata "postgresql.conf") "`nport = $PGPORT`nlisten_addresses = 'localhost'`n"
    Ok "initdb tamam"
  }
  pg_ctl -D $pgdata -l (Join-Path $pgdata "server.log") start | Out-Null
  Start-Sleep 2
  Ok "cluster çalışıyor"
  exit 0
}

# ---- bağlantı stringi
if($Mode -eq "Supabase"){
  # supabase start sonrası yerel stack: 54322 / postgres / postgres
  $connBase = "postgresql://postgres:postgres@localhost:54322/postgres"
  $connDb   = $connBase
} else {
  $connBase = "postgresql://${PGUSER}@${PGHOST}:${PGPORT}/postgres"
  $connDb   = "postgresql://${PGUSER}@${PGHOST}:${PGPORT}/${PGDB}"
}

function Run-Sql([string]$conn,[string]$file){
  Write-Host "    -> $file"
  # ON_ERROR_STOP: ilk hatada dur; -X: psqlrc yok; stderr+stdout log'a
  $out = & psql $conn -X -v ON_ERROR_STOP=1 -f $file 2>&1
  $out | Add-Content $log
  if($LASTEXITCODE -ne 0){ $out | Select-Object -Last 15 | ForEach-Object { Fail $_ }; throw "HATA: $file" }
}

"# BoutiqueOS fresh apply — $(Get-Date -Format s) — mode=$Mode" | Set-Content $log

# ---- 1. fresh DB
Step "Fresh database ($Mode)"
if($Mode -eq "Plain"){
  & psql $connBase -X -c "DROP DATABASE IF EXISTS $PGDB WITH (FORCE);" | Out-Null
  & psql $connBase -X -c "CREATE DATABASE $PGDB;" | Out-Null
  Ok "$PGDB yeniden oluşturuldu"
} else {
  & supabase db reset --local | Out-Null   # migrations klasörünü kendisi uygular
  Ok "supabase db reset"
}

# ---- 2. harness (sadece Plain)
if($Mode -eq "Plain"){
  Step "Test harness"
  Run-Sql $connDb "tests\000_test_harness.sql"
}

# ---- 3. migrations (Supabase modunda reset zaten uyguladı)
if($Mode -eq "Plain"){
  Step "Migrations"
  Get-ChildItem "supabase\migrations\*.sql" | Sort-Object Name | ForEach-Object { Run-Sql $connDb $_.FullName }
}

# ---- 4. seeds
Step "Seeds"
Get-ChildItem "seeds\*.sql" | Sort-Object Name | ForEach-Object { Run-Sql $connDb $_.FullName }

# ---- 5. tests
if(-not $NoTests){
  Step "Verification tests"
  $tfile = "tests\005_verification_tests.sql"
  # testler bir transaction içinde, sonunda ROLLBACK
  $out = & psql $connDb -X -v ON_ERROR_STOP=0 -c "BEGIN;" -f $tfile -c "ROLLBACK;" 2>&1
  $out | Add-Content $log
  $pass = ($out | Select-String '\[PASS\]').Count
  $fail = ($out | Select-String '\[FAIL\]|ERROR:').Count
  $out | Select-String '\[FAIL\]|ERROR:' | ForEach-Object { Fail $_.Line }
  Write-Host "`n    PASS: $pass   FAIL/ERROR: $fail" -ForegroundColor $(if($fail -eq 0){"Green"}else{"Red"})
  Write-Host "    log: $log"
  if($fail -gt 0){ exit 1 }
}
Ok "tamamlandı"
exit 0
