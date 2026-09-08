<#
.SYNOPSIS
  BoutiqueOS — proje iskeleti + yerel araçlar (Windows / PowerShell 7 veya 5.1)

.USAGE
  Set-ExecutionPolicy -Scope Process Bypass
  .\bootstrap.ps1 -Root "E:\BoutiqueOS\Butik"        # mevcut dosyaları yeni düzene taşır
  .\bootstrap.ps1 -Root "E:\BoutiqueOS\Butik" -SkipTools   # sadece klasör/git

.WHAT IT DOES
  1. Klasör yapısını kurar (docs/, supabase/migrations/, seeds/, tests/, scripts/)
  2. Kökte duran Rev 2 dosyalarını doğru klasörlere TAŞIR ve _1/_2 eklerini temizler
  3. git init + .gitignore + ilk commit
  4. Araçları kontrol eder / kurar (scoop → git, postgresql, supabase)
  5. Docker Desktop var mı bakar (Supabase local stack için gerekir; opsiyonel)
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

# ---------------------------------------------------------------- 1. klasörler
Step "Klasör yapısı: $Root"
$dirs = "docs","supabase\migrations","seeds","tests","tests\results","scripts","app"
foreach($d in $dirs){ New-Item -ItemType Directory -Force -Path (Join-Path $Root $d) | Out-Null }
Ok "klasörler hazır"

# ---------------------------------------------------------------- 2. dosya taşıma
Step "Mevcut dosyaları düzenle (varsa)"
$map = @{
  # kaynak (glob)                 -> hedef (göreli)
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
    if(Test-Path $dst){ Warn "hedef zaten var, atlandı: $($map[$k])"; continue }
    Move-Item $src.FullName $dst
    Ok "$($src.Name) -> $($map[$k])"
  }
}

# ---------------------------------------------------------------- 3. git
if(-not $SkipGit){
  Step "git"
  if(-not (Get-Command git -ErrorAction SilentlyContinue)){ Warn "git yok; araç kurulumundan sonra tekrar çalıştır"; }
  else {
    Push-Location $Root
    if(-not (Test-Path ".git")){ git init -b main | Out-Null; Ok "git init" }
    git add -A | Out-Null
    $pending = git status --porcelain
    if($pending){ git commit -q -m "chore: bootstrap project layout (Rev 2 files, pre-flight report)"; Ok "ilk commit" } else { Ok "commit edilecek değişiklik yok" }
    Pop-Location
  }
}

# ---------------------------------------------------------------- 4. araçlar
if(-not $SkipTools){
  Step "Araçlar (scoop)"
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

  Step "Docker Desktop (Supabase local stack için, opsiyonel)"
  if(Get-Command docker -ErrorAction SilentlyContinue){ Ok "docker bulundu" }
  else { Warn "docker yok. Plain PostgreSQL modu (scripts\db_fresh.ps1) Docker istemez. Supabase local için: https://www.docker.com/products/docker-desktop" }
}

Step "Bitti"
Write-Host @"
Sonraki adımlar:
  cd $Root
  copy .env.example .env            # gerekirse PGPORT/parola düzenle
  .\scripts\db_fresh.ps1 -Init      # yerel PostgreSQL cluster (.pgdata) oluştur + başlat
  .\scripts\db_fresh.ps1            # sıfırdan: harness -> 001..004 -> seed -> 005 testleri
"@
