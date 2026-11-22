# Tofu WoW patcher for Windows. "Tofu WoW (Windows).bat" runs it with -Launch.
# It reads the newest manifest.txt from the GitHub release of cdenq/wow-tofuworld-patches and makes this client match it: Tofu patches in Data, the HD patch keep list, the Tofu addon pack, and realmlist.wtf. Then it starts WoW.
# -Source <folder> reads manifest.txt and every file from that folder instead of GitHub (used by publish.sh on the host).
param(
  [string]$WowDir = '',
  [string]$Source = '',
  [switch]$Launch,
  [switch]$Restarted
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ManifestUrl = 'https://github.com/cdenq/wow-tofuworld-patches/releases/latest/download/manifest.txt'
$Me = 'tofu-patcher.ps1'
$Blizzard = @('patch.mpq', 'patch-2.mpq', 'patch-3.mpq')

if (-not $WowDir) { $WowDir = Split-Path -Parent $PSScriptRoot }
$WowDir = (Resolve-Path -LiteralPath $WowDir).Path
$Tofu = Join-Path $WowDir 'Tofu'
$Data = Join-Path $WowDir 'Data'
$Temp = Join-Path $Tofu 'downloads'
$HashFile = Join-Path $Tofu 'hashes.txt'
$AddonFolders = Join-Path $Tofu 'addon-folders.txt'
$AddonSha = Join-Path $Tofu 'addon-pack.txt'
$script:Warnings = 0
$script:Changed = $false

function Say($m) { Write-Host $m }
function Warn($m) { Write-Host "  WARNING: $m" -ForegroundColor Yellow; $script:Warnings++ }
function Stop-With($m) {
  Write-Host ''
  Write-Host $m -ForegroundColor Red
  Write-Host 'If this keeps happening, send Chris a screenshot of this window.'
  exit 1
}
function Start-Wow {
  if (-not $Launch) { return }
  if ($script:Warnings -gt 0) { Read-Host 'There were warnings above. Press Enter to start WoW anyway' | Out-Null }
  Say 'Starting WoW...'
  Start-Process -FilePath (Join-Path $WowDir 'Wow.exe') -WorkingDirectory $WowDir
  Start-Sleep -Seconds 2
}

# Hashes are cached by size and modified time, so large patches are not re-hashed on every launch.
$script:Cache = @{}
if (Test-Path -LiteralPath $HashFile) {
  foreach ($l in Get-Content -LiteralPath $HashFile) {
    $p = $l -split "`t"
    if ($p.Count -eq 4) { $script:Cache[$p[0]] = $p }
  }
}
function Get-Sha1([string]$path) {
  $f = Get-Item -LiteralPath $path
  $key = $f.FullName.ToLower()
  $size = [string]$f.Length
  $stamp = [string]$f.LastWriteTimeUtc.Ticks
  $c = $script:Cache[$key]
  if ($c -and $c[1] -eq $size -and $c[2] -eq $stamp) { return $c[3] }
  $h = (Get-FileHash -LiteralPath $path -Algorithm SHA1).Hash.ToLower()
  $script:Cache[$key] = @($key, $size, $stamp, $h)
  return $h
}
function Save-Hashes {
  $lines = foreach ($v in $script:Cache.Values) { $v -join "`t" }
  Set-Content -LiteralPath $HashFile -Value $lines -Encoding ASCII
}

# Gets one file into $dest: copied from -Source, or downloaded from $url.
function Get-TofuFile([string]$name, [string]$url, [string]$dest) {
  if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
  if ($Source) {
    Copy-Item -LiteralPath (Join-Path $Source $name) -Destination $dest -Force
    return
  }
  if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
    & curl.exe -L --fail --retry 3 --show-error --progress-bar -o $dest $url
    if ($LASTEXITCODE -ne 0) { throw "download of $name failed (curl exit code $LASTEXITCODE)" }
  } else {
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
  }
}

# Gets a file, checks its SHA-1, and only then moves it into place, so a failed download never leaves a broken file.
function Install-TofuFile($entry, [string]$dest) {
  $tmp = Join-Path $Temp ($entry.Name + '.part')
  Get-TofuFile $entry.Name $entry.Url $tmp
  $got = (Get-FileHash -LiteralPath $tmp -Algorithm SHA1).Hash.ToLower()
  if ($got -ne $entry.Sha1) {
    Remove-Item -LiteralPath $tmp -Force
    throw "$($entry.Name) did not match its checksum after downloading"
  }
  if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
  Move-Item -LiteralPath $tmp -Destination $dest
}

function Read-Manifest([string]$path) {
  $m = @{ Version = ''; Realmlist = ''; Keep = @(); Standard = @(); Scripts = @(); Data = @(); Addons = $null }
  foreach ($raw in Get-Content -LiteralPath $path) {
    $l = $raw.TrimEnd("`r")
    if (-not $l -or $l.StartsWith('#')) { continue }
    $p = $l -split "`t"
    $rest = @()
    if ($p.Count -gt 1) { $rest = @($p[1..($p.Count - 1)]) }
    switch ($p[0]) {
      'version' { $m.Version = $p[1] }
      'realmlist' { $m.Realmlist = $p[1] }
      'keep' { $m.Keep = @($rest | ForEach-Object { $_.ToLower() }) }
      'standard' { $m.Standard = $rest }
      default {
        if ($p[0] -in @('script', 'data', 'addons')) {
          $e = [pscustomobject]@{ Name = $p[1]; Sha1 = $p[2].ToLower(); Size = [int64]$p[3]; Url = $p[4]; Folders = @() }
          if ($p[0] -eq 'addons' -and $p.Count -gt 5) { $e.Folders = @($p[5] -split '\|' | Where-Object { $_ }) }
          if ($p[0] -eq 'script') { $m.Scripts += $e }
          elseif ($p[0] -eq 'data') { $m.Data += $e }
          else { $m.Addons = $e }
        }
      }
    }
  }
  if (-not $m.Version) { throw 'the manifest has no version line' }
  return $m
}

# ---- checks ----
if (-not (Test-Path -LiteralPath (Join-Path $WowDir 'Wow.exe'))) {
  Stop-With "Could not find Wow.exe in $WowDir. Keep the Tofu folder and the Tofu WoW launchers in your WoW folder, next to Wow.exe."
}
if (Get-Process -Name 'Wow' -ErrorAction SilentlyContinue) {
  Stop-With 'WoW is already running. Close the game, then run Tofu WoW again.'
}
New-Item -ItemType Directory -Force -Path $Temp | Out-Null
if (-not $Restarted) {
  # Files unzipped from a download carry Windows' "from the internet" mark; clear it on our own files.
  Get-ChildItem -LiteralPath $Tofu -File | Unblock-File -ErrorAction SilentlyContinue
  Get-ChildItem -LiteralPath $WowDir -Filter 'Tofu WoW*' -File | Unblock-File -ErrorAction SilentlyContinue
}

Say 'Tofu WoW: checking for updates...'
$manifestPath = Join-Path $Temp 'manifest.txt'
try {
  Get-TofuFile 'manifest.txt' $ManifestUrl $manifestPath
  $M = Read-Manifest $manifestPath
} catch {
  Write-Host "  Could not reach the update server ($($_.Exception.Message))." -ForegroundColor Yellow
  if ($Launch) { $cache = Join-Path $WowDir 'Cache'; if (Test-Path -LiteralPath $cache) { Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue }; Say '  Starting WoW without updating.'; $script:Warnings = 0; Start-Wow; exit 0 }
  exit 1
}

try {
  # ---- 1. the patcher scripts (this one restarts itself when it changes) ----
  $restart = $false
  foreach ($s in $M.Scripts) {
    $dest = Join-Path $Tofu $s.Name
    if ((Test-Path -LiteralPath $dest) -and (Get-Sha1 $dest) -eq $s.Sha1) { continue }
    Install-TofuFile $s $dest
    Say "  updated $($s.Name)"
    if ($s.Name -eq $Me) { $restart = $true }
  }
  Save-Hashes
  if ($restart -and -not $Restarted) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-WowDir', $WowDir, '-Restarted')
    if ($Source) { $a += @('-Source', $Source) }
    if ($Launch) { $a += '-Launch' }
    & powershell.exe @a
    exit $LASTEXITCODE
  }

  Say "  newest version: $($M.Version)"

  # ---- 2. move out every patch that is not Blizzard's, a kept HD patch, or a Tofu patch ----
  $allowed = @($Blizzard) + @($M.Keep) + @($M.Data | ForEach-Object { $_.Name.ToLower() })
  $moved = Join-Path $Data 'Removed Patches'
  foreach ($f in Get-ChildItem -LiteralPath $Data -Filter 'patch-*.mpq' -File) {
    if ($allowed -contains $f.Name.ToLower()) { continue }
    $official = $M.Data | Where-Object { $_.Name -ieq $f.Name }
    if ($official) { continue }
    New-Item -ItemType Directory -Force -Path $moved | Out-Null
    $target = Join-Path $moved $f.Name
    if (Test-Path -LiteralPath $target) { $target = Join-Path $moved ("{0}.{1}{2}" -f $f.BaseName, (Get-Date -Format 'yyyyMMddHHmmss'), $f.Extension) }
    Move-Item -LiteralPath $f.FullName -Destination $target
    Say "  moved $($f.Name) to Data\Removed Patches"
    $script:Changed = $true
  }

  # ---- 3. HD patches every player needs: copy from Data\OPTIONAL PATCHES when missing ----
  $opt = Join-Path $Data 'OPTIONAL PATCHES'
  foreach ($p in $M.Standard) {
    if (Test-Path -LiteralPath (Join-Path $Data $p)) { continue }
    if (Test-Path -LiteralPath (Join-Path $opt $p)) {
      Copy-Item -LiteralPath (Join-Path $opt $p) -Destination (Join-Path $Data $p)
      Say "  added $p from OPTIONAL PATCHES"
      $script:Changed = $true
    } else {
      Warn "$p is missing and is not in Data\OPTIONAL PATCHES. Ask Chris for it."
    }
  }

  # ---- 4. Tofu patches ----
  foreach ($d in $M.Data) {
    $dest = Join-Path $Data $d.Name
    $have = ''
    if (Test-Path -LiteralPath $dest) { $have = Get-Sha1 $dest }
    if ($have -eq $d.Sha1) { continue }
    if ($d.Url -eq 'bundled' -and -not ($Source -and (Test-Path -LiteralPath (Join-Path $Source $d.Name)))) {
      Warn "$($d.Name) is missing or out of date, and it is too large to download here. Ask Chris for the current client."
      continue
    }
    Say ("  downloading {0} ({1:N0} MB)" -f $d.Name, ($d.Size / 1MB))
    Install-TofuFile $d $dest
    $script:Changed = $true
  }
  Save-Hashes

  # ---- 5. Tofu addon pack: replaces only the folders Tofu manages ----
  if ($M.Addons) {
    $haveSha = ''
    if (Test-Path -LiteralPath $AddonSha) { $haveSha = (Get-Content -LiteralPath $AddonSha | Select-Object -First 1) }
    $addonDir = Join-Path $WowDir 'Interface\AddOns'
    $missing = @($M.Addons.Folders | Where-Object { -not (Test-Path -LiteralPath (Join-Path $addonDir $_)) })
    if ($haveSha -ne $M.Addons.Sha1 -or $missing.Count -gt 0) {
      Say ("  downloading addons ({0:N0} MB)" -f ($M.Addons.Size / 1MB))
      $zip = Join-Path $Temp $M.Addons.Name
      Install-TofuFile $M.Addons $zip
      New-Item -ItemType Directory -Force -Path $addonDir | Out-Null
      $old = @()
      if (Test-Path -LiteralPath $AddonFolders) { $old = @(Get-Content -LiteralPath $AddonFolders) }
      foreach ($name in (@($old) + @($M.Addons.Folders) | Sort-Object -Unique)) {
        if (-not $name -or $name -like 'Blizzard_*' -or $name -match '[\\/:]' -or $name -match '\.\.') { continue }
        $path = Join-Path $addonDir $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
      }
      Expand-Archive -LiteralPath $zip -DestinationPath $addonDir -Force
      Remove-Item -LiteralPath $zip -Force
      Set-Content -LiteralPath $AddonFolders -Value $M.Addons.Folders -Encoding UTF8
      Set-Content -LiteralPath $AddonSha -Value $M.Addons.Sha1 -Encoding ASCII
      Say "  installed $($M.Addons.Folders.Count) addon folders"
      $script:Changed = $true
    }
  }

  # ---- 6. realmlist ----
  if ($M.Realmlist) {
    $want = "set realmlist $($M.Realmlist)"
    $files = @(Get-ChildItem -LiteralPath $Data -Directory | ForEach-Object { Join-Path $_.FullName 'realmlist.wtf' } | Where-Object { Test-Path -LiteralPath $_ })
    if ($files.Count -eq 0) { Warn 'Could not find realmlist.wtf in any Data language folder.' }
    foreach ($r in $files) {
      $now = (Get-Content -LiteralPath $r -Raw)
      if ($now -eq $null -or $now.Trim() -ne $want) {
        Set-Content -LiteralPath $r -Value $want -Encoding ASCII
        Say "  set the realmlist to $($M.Realmlist)"
      }
    }
  }

  # ---- 6b. Wow.exe name check ----
  # The stock 3.3.5a client (build 12340) checks character names itself (ValidateName, file offset 0x2B0390) and refuses digits, three letters in a row, and reserved names before the server sees them. Tofu Worldview lets the server decide, so that function is made to return CHAR_NAME_SUCCESS (0x57) at once: 55 8B EC 8B 45 08 becomes B8 57 00 00 00 C3 (mov eax, 0x57; ret), the same change mod-two-names documents. Only a Wow.exe with exactly the stock or the patched bytes there is touched, and the first change saves the original as Tofu\Wow.exe.original.
  $exe = Join-Path $WowDir 'Wow.exe'
  $nameOff = 0x2B0390
  $nameStock = [byte[]](0x55, 0x8B, 0xEC, 0x8B, 0x45, 0x08)
  $namePatched = [byte[]](0xB8, 0x57, 0x00, 0x00, 0x00, 0xC3)
  try {
    $bytes = [IO.File]::ReadAllBytes($exe)
    $now = [byte[]]::new(6)
    if ($bytes.Length -ge $nameOff + 6) { [Array]::Copy($bytes, $nameOff, $now, 0, 6) }
    $ver = (Get-Item -LiteralPath $exe).VersionInfo
    if ([Linq.Enumerable]::SequenceEqual($now, $namePatched)) {
      # already patched
    } elseif (-not [Linq.Enumerable]::SequenceEqual($now, $nameStock) -or ($ver.FileMajorPart -eq 3 -and $ver.FilePrivatePart -ne 12340)) {
      Say '  note: this Wow.exe is not the standard 3.3.5a build, so its name check was left alone (character names may be limited to letters).'
    } else {
      $orig = Join-Path $Tofu 'Wow.exe.original'
      if (-not (Test-Path -LiteralPath $orig)) { Copy-Item -LiteralPath $exe -Destination $orig }
      $fs = [IO.File]::Open($exe, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
      try { $fs.Position = $nameOff; $fs.Write($namePatched, 0, 6) } finally { $fs.Close() }
      Say '  allowed numbers, repeated letters, and more in character names (Wow.exe updated; the original is in Tofu\Wow.exe.original)'
      $script:Changed = $true
    }
  } catch {
    Warn "Could not update Wow.exe to allow numbers in character names ($($_.Exception.Message)). Everything else works."
  }

  # ---- 7. clean up ----
  $legacy = Join-Path $WowDir 'Tofu Patches'
  if (Test-Path -LiteralPath $legacy) { Remove-Item -LiteralPath $legacy -Recurse -Force; Say '  removed the old Tofu Patches folder' }
  # Cache holds the item, creature, and quest data the server sends; it is cleared at every launch so server-side changes (custom SQL with no new patch) always show (Chris, 2026-11-19).
  $cache = Join-Path $WowDir 'Cache'
  if (Test-Path -LiteralPath $cache) { Remove-Item -LiteralPath $cache -Recurse -Force; Say '  cleared the Cache folder' }
  Set-Content -LiteralPath (Join-Path $Data 'Tofu Patch Version.txt') -Value "Tofu Worldview patches, version $($M.Version)" -Encoding ASCII
  Set-Content -LiteralPath (Join-Path $Tofu 'version.txt') -Value $M.Version -Encoding ASCII
} catch {
  Save-Hashes
  Stop-With "Update failed: $($_.Exception.Message). Make sure WoW is closed and you are online, then try again."
}

if ($script:Changed) { Say "Updated to Tofu Worldview $($M.Version)." } else { Say "Up to date ($($M.Version))." }
Start-Wow
exit 0
