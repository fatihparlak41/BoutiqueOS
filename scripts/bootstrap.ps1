<#
.SYNOPSIS
  BoutiqueOS - proje iskeleti + yerel araclar (Windows / PowerShell 7 veya 5.1)

.USAGE
  Set-ExecutionPolicy -Scope Process Bypass
  .\bootstrap.ps1 -Root "E:\BoutiqueOS\Butik"        # mevcut dosyalari yeni duzene tasir
  .\bootstrap.ps1 -Root "E:\BoutiqueOS\Butik" -SkipTools   # sadece klasor/git

.WHAT IT DOES
  1. Klasor yapisini kurar (docs/, supabase/migrations/, seeds/, tests/, scripts/)
  2. Kokte duran Rev 2 dosyalarini dogru klasorlere TASIR ve _1/_2 eklerini temizler
  3. git init + .gitignore + ilk commit
  4. Araclari kontrol eder / kurar (scoop  git, postgresql, supabase)
  5. Docker Desktop var mi bakar (Supabase local stack icin gerekir; opsiyonel)
#>
[CmdletBinding()]
param(
  [string]$Root = "E:\BoutiqueOS\Butik",
  [switch]$SkipTools,
  [switch]$SkipGit
)
$ErrorActionPreference = "Stop"
function Step($m){ Write-Host "`n==> $m" -ForegroundColor Cyan }
function Ok($m){ Write-Host "    [OK] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "    [!!] $m" -ForegroundColor Yellow }

# ---------------------------------------------------------------- 1. klasorler
Step "Klasor yapisi: $Root"
$dirs = "docs","supabase\migrations","seeds","tests","tests\results","scripts","app"
foreach($d in $dirs){ New-Item -ItemType Directory -Force -Path (Join-Path $Root $d) | Out-Null }
Ok "klasorler hazir"

# ---------------------------------------------------------------- 2. dosya tasima
Step "Mevcut dosyalari duzenle (varsa)"
$map = @{
  # kaynak (glob)                 -> hedef (goreli)
  "00_PROJECT_OVERVIEW.md"        = "docs\00_PROJECT_OVERVIEW.md"
  "01_REQUIREMENTS.md"            = "docs\01_REQUIREMENTS.md"
  "02_DOMAIN_MODEL.md"            = "docs\02_DOMAIN_MODEL.md"
  "09_DECISIONS.md"               = "docs\09_DECISIONS.md"
  "10_AUDIT_REVIEW.md"            = "docs\10_AUDIT_REVIEW.md"
  "pilot-analiz.html"             = "docs\pilot-analiz.html"
  "REV3_PREFLIGHT_REPORT.md"      = "docs\11_REV3_PREFLIGHT_REPORT.md"
  "001_schema*.sql"               = "supabase\migrations\001_schema.sql"
  "002_schema_cont*.sql"          = "supabase\migrations\002_schema_cont.sql"
  "003_schema_pilot*.sql"         = "supabase\migrations\003_schema_pilot.sql"
  "004_rpc_posting*.sql"          = "supabase\migrations\004_rpc_posting.sql"
  "seed_things_like_crop*.sql"    = "seeds\seed_things_like_crop.sql"
  "000_test_harness.sql"          = "tests\000_test_harness.sql"
  "005_verification_tests.sql"    = "tests\005_verification_tests.sql"
}
foreach($k in $map.Keys){
  $src = Get-ChildItem -Path $Root -Filter $k -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if($src){
    $dst = Join-Path $Root $map[$k]
    if(Test-Path $dst){ Warn "hedef zaten var, atlandi: $($map[$k])"; continue }
    Move-Item $src.FullName $dst
    Ok "$($src.Name) -> $($map[$k])"
  }
}

# ---------------------------------------------------------------- 3. git
if(-not $SkipGit){
  Step "git"
  if(-not (Get-Command git -ErrorAction SilentlyContinue)){ Warn "git yok; arac kurulumundan sonra tekrar calistir"; }
  else {
    Push-Location $Root
    if(-not (Test-Path ".git")){ git init -b main | Out-Null; Ok "git init" }
    git add -A | Out-Null
    $pending = git status --porcelain
    if($pending){ git commit -q -m "chore: bootstrap project layout (Rev 2 files, pre-flight report)"; Ok "ilk commit" } else { Ok "commit edilecek degisiklik yok" }
    Pop-Location
  }
}

# ---------------------------------------------------------------- 4. araclar
if(-not $SkipTools){
  Step "Araclar (scoop)"
  if(-not (Get-Command scoop -ErrorAction SilentlyContinue)){
    Warn "scoop kuruluyor..."
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    Invoke-RestMethod -Uri https://get.scoop.sh | Invoke-Expression
  }
  scoop bucket add main 2>$null | Out-Null
  scoop bucket add supabase https://github.com/supabase/scoop-bucket.git 2>$null | Out-Null

  foreach($pkg in "git","postgresql","supabase"){
    $cmd = @{ git="git"; postgresql="psql"; supabase="supabase" }[$pkg]
    if(Get-Command $cmd -ErrorAction SilentlyContinue){ Ok "$pkg zaten var: $((Get-Command $cmd).Source)" }
    else { scoop install $pkg; Ok "$pkg kuruldu" }
  }

  Step "Docker Desktop (Supabase local stack icin, opsiyonel)"
  if(Get-Command docker -ErrorAction SilentlyContinue){ Ok "docker bulundu" }
  else { Warn "docker yok. Plain PostgreSQL modu (scripts\db_fresh.ps1) Docker istemez. Supabase local icin: https://www.docker.com/products/docker-desktop" }
}

Step "Bitti"
Write-Host @"
Sonraki adimlar:
  cd $Root
  copy .env.example .env            # gerekirse PGPORT/parola duzenle
  .\scripts\db_fresh.ps1 -Init      # yerel PostgreSQL cluster (.pgdata) olustur + baslat
  .\scripts\db_fresh.ps1            # sifirdan: harness -> 001..004 -> seed -> 005 testleri
"@
