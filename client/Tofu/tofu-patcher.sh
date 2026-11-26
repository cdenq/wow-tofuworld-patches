#!/bin/bash
# Tofu WoW patcher for Mac (the Windows client running under CrossOver, Whisky, or Wine). "Tofu WoW (Mac).command" runs it with --launch.
# Same job as tofu-patcher.ps1: reads the newest manifest.txt from the GitHub release of cdenq/wow-tofuworld-patches and makes this client match it, then starts WoW if it can.
# Written for the bash 3.2 that ships with macOS: no associative arrays, no ${x,,}.

set -u
MANIFEST_URL="${TOFU_MANIFEST_URL:-https://github.com/cdenq/wow-tofuworld-patches/releases/latest/download/manifest.txt}"
ME='tofu-patcher.sh'
BLIZZARD='patch.mpq patch-2.mpq patch-3.mpq'
TAB=$(printf '\t')

LAUNCH=0
[ "${1:-}" = "--launch" ] && LAUNCH=1
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
TOFU="$(dirname "$SELF")"
WOW="$(dirname "$TOFU")"
DATA="$WOW/Data"
TMP="$TOFU/downloads"
HASHES="$TOFU/hashes.txt"
ADDON_FOLDERS="$TOFU/addon-folders.txt"
ADDON_SHA="$TOFU/addon-pack.txt"
WARNINGS=0
CHANGED=0

say() { printf '%s\n' "$1"; }
warn() { printf '  WARNING: %s\n' "$1"; WARNINGS=$((WARNINGS + 1)); }
stop_with() { printf '\n%s\nIf this keeps happening, send Chris a screenshot of this window.\n' "$1"; exit 1; }
lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

start_wow() {
  [ "$LAUNCH" = 1 ] || return 0
  if [ "$WARNINGS" -gt 0 ]; then printf 'There were warnings above. Press Return to continue. '; read -r _; fi
  local wine=''
  for w in wine64 wine; do if command -v "$w" >/dev/null 2>&1; then wine="$w"; break; fi; done
  if [ -n "$wine" ]; then
    say 'Starting WoW...'
    (cd "$WOW" && nohup "$wine" Wow.exe >/dev/null 2>&1 &)
  else
    say 'Now start WoW the way you usually do (CrossOver, Whisky, or similar).'
  fi
}

# Hashes are cached by size and modified time, so large patches are not re-hashed on every launch.
touch "$HASHES" 2>/dev/null
sha1_of() {
  local f="$1" st line h
  if [ "$(uname)" = Darwin ]; then st=$(stat -f "%z$TAB%m" "$f"); else st=$(stat -c "%s$TAB%Y" "$f"); fi
  line=$(grep -F -- "$f$TAB$st$TAB" "$HASHES" | head -n 1)
  if [ -n "$line" ]; then printf '%s\n' "${line##*$TAB}"; return; fi
  h=$(shasum -a 1 "$f" | cut -d' ' -f1)
  grep -v -F -- "$f$TAB" "$HASHES" > "$HASHES.tmp"
  printf '%s\n' "$f$TAB$st$TAB$h" >> "$HASHES.tmp"
  mv "$HASHES.tmp" "$HASHES"
  printf '%s\n' "$h"
}

# Downloads a file, checks its SHA-1, and only then moves it into place.
install_file() { # name sha1 url dest
  local part="$TMP/$1.part" got
  rm -f "$part"
  curl -L --fail --retry 3 --show-error --progress-bar -o "$part" "$3" || { rm -f "$part"; return 1; }
  got=$(shasum -a 1 "$part" | cut -d' ' -f1)
  if [ "$got" != "$2" ]; then rm -f "$part"; say "  $1 did not match its checksum after downloading"; return 1; fi
  rm -f "$4"
  mv "$part" "$4"
}

# ---- checks ----
[ -f "$WOW/Wow.exe" ] || stop_with "Could not find Wow.exe in $WOW. Keep the Tofu folder and the Tofu WoW launchers in your WoW folder, next to Wow.exe."
if pgrep -if '(^|[\\/ ])wow\.exe( |$)' >/dev/null 2>&1; then stop_with 'WoW is already running. Close the game, then run Tofu WoW again.'; fi
mkdir -p "$TMP"
# Make the Mac launcher double-clickable from now on (zips made on Windows drop the executable bit).
for c in "$WOW"/Tofu\ WoW*.command; do
  [ -f "$c" ] || continue
  chmod +x "$c" 2>/dev/null
  xattr -d com.apple.quarantine "$c" 2>/dev/null
done

say 'Tofu WoW: checking for updates...'
MF="$TMP/manifest.txt"
if ! curl -L --fail --silent --show-error --retry 3 -o "$MF" "$MANIFEST_URL" || ! grep -q '^version' "$MF"; then
  say '  Could not reach the update server.'
  if [ "$LAUNCH" = 1 ]; then rm -rf "$WOW/Cache"; say '  Starting without updating.'; WARNINGS=0; start_wow; exit 0; fi
  exit 1
fi
tr -d '\r' < "$MF" | grep -v '^#' > "$MF.clean"

field() { grep "^$1$TAB" "$MF.clean" | head -n 1 | cut -f "$2"; }
VERSION=$(field version 2)
REALMLIST=$(field realmlist 2)
KEEP=$(lower "$(grep "^keep$TAB" "$MF.clean" | cut -f 2- | tr '\t' ' ')")
STANDARD=$(grep "^standard$TAB" "$MF.clean" | cut -f 2- | tr '\t' ' ')

# ---- 1. the patcher scripts (this one restarts itself when it changes) ----
RESTART=0
while IFS="$TAB" read -r kind name sha size url rest <&3; do
  [ "$kind" = script ] || continue
  dest="$TOFU/$name"
  if [ -f "$dest" ] && [ "$(sha1_of "$dest")" = "$sha" ]; then continue; fi
  install_file "$name" "$sha" "$url" "$dest" || stop_with "Update failed while downloading $name. Check that you are online, then try again."
  say "  updated $name"
  [ "$name" = "$ME" ] && RESTART=1
done 3< "$MF.clean"
if [ "$RESTART" = 1 ] && [ -z "${TOFU_RESTARTED:-}" ]; then
  # The old file was replaced by a rename, so this running copy is untouched; hand over to the new one.
  TOFU_RESTARTED=1 exec bash "$TOFU/$ME" "$@"
fi
say "  newest version: $VERSION"

DATA_NAMES=$(lower "$(grep "^data$TAB" "$MF.clean" | cut -f 2 | tr '\n' ' ')")

# ---- 2. move out every patch that is not Blizzard's, a kept HD patch, or a Tofu patch ----
shopt -s nullglob
for f in "$DATA"/[Pp][Aa][Tt][Cc][Hh]-*.[Mm][Pp][Qq]; do
  n=$(basename "$f")
  ln=$(lower "$n")
  if in_list "$ln" "$BLIZZARD $KEEP $DATA_NAMES"; then continue; fi
  mkdir -p "$DATA/Removed Patches"
  target="$DATA/Removed Patches/$n"
  [ -e "$target" ] && target="$DATA/Removed Patches/${n%.*}.$(date +%Y%m%d%H%M%S).${n##*.}"
  mv "$f" "$target" && say "  moved $n to Data/Removed Patches"
  CHANGED=1
done

# ---- 3. HD patches every player needs: copy from Data/OPTIONAL PATCHES when missing ----
for p in $STANDARD; do
  [ -f "$DATA/$p" ] && continue
  if [ -f "$DATA/OPTIONAL PATCHES/$p" ]; then
    cp "$DATA/OPTIONAL PATCHES/$p" "$DATA/$p" && say "  added $p from OPTIONAL PATCHES"
    CHANGED=1
  else
    warn "$p is missing and is not in Data/OPTIONAL PATCHES. Ask Chris for it."
  fi
done

# ---- 4. Tofu patches ----
while IFS="$TAB" read -r kind name sha size url rest <&3; do
  [ "$kind" = data ] || continue
  dest="$DATA/$name"
  # Find an existing copy whatever its letter case.
  for e in "$DATA"/*; do [ "$(lower "$(basename "$e")")" = "$(lower "$name")" ] && dest="$e"; done
  have=''
  [ -f "$dest" ] && have=$(sha1_of "$dest")
  [ "$have" = "$sha" ] && continue
  if [ "$url" = bundled ]; then warn "$name is missing or out of date, and it is too large to download here. Ask Chris for the current client."; continue; fi
  say "  downloading $name ($((size / 1048576)) MB)"
  rm -f "$dest"
  install_file "$name" "$sha" "$url" "$DATA/$name" || stop_with "Update failed while downloading $name. Check that you are online, then try again."
  CHANGED=1
done 3< "$MF.clean"

# ---- 5. Tofu addon pack: replaces only the folders Tofu manages ----
ADDONS=$(grep "^addons$TAB" "$MF.clean" | head -n 1)
if [ -n "$ADDONS" ]; then
  IFS="$TAB" read -r kind name sha size url folders <<EOF
$ADDONS
EOF
  AD="$WOW/Interface/AddOns"
  havesha=$(head -n 1 "$ADDON_SHA" 2>/dev/null)
  missing=0
  OLDIFS=$IFS; IFS='|'
  for d in $folders; do [ -n "$d" ] && [ ! -d "$AD/$d" ] && missing=1; done
  IFS=$OLDIFS
  if [ "$havesha" != "$sha" ] || [ "$missing" = 1 ]; then
    say "  downloading addons ($((size / 1048576)) MB)"
    install_file "$name" "$sha" "$url" "$TMP/$name" || stop_with 'Update failed while downloading the addons. Check that you are online, then try again.'
    mkdir -p "$AD"
    { [ -f "$ADDON_FOLDERS" ] && cat "$ADDON_FOLDERS"; printf '%s\n' "$folders" | tr '|' '\n'; } | sort -u | while IFS= read -r d; do
      case "$d" in ''|Blizzard_*|*/*|*..*) continue ;; esac
      rm -rf "$AD/$d"
    done
    unzip -q -o "$TMP/$name" -d "$AD" || stop_with 'Could not unpack the addons.'
    rm -f "$TMP/$name"
    printf '%s\n' "$folders" | tr '|' '\n' > "$ADDON_FOLDERS"
    printf '%s\n' "$sha" > "$ADDON_SHA"
    say '  installed the Tofu addons'
    CHANGED=1
  fi
fi

# ---- 6. realmlist ----
if [ -n "$REALMLIST" ]; then
  want="set realmlist $REALMLIST"
  found=0
  for r in "$DATA"/*/realmlist.wtf; do
    found=1
    if [ "$(tr -d '\r' < "$r" | sed '/^[[:space:]]*$/d')" != "$want" ]; then
      printf '%s\r\n' "$want" > "$r"
      say "  set the realmlist to $REALMLIST"
    fi
  done
  [ "$found" = 1 ] || warn 'Could not find realmlist.wtf in any Data language folder.'
fi

# ---- 6b. Wow.exe name check ----
# The stock 3.3.5a client (build 12340) checks character names itself (ValidateName, file offset 0x2B0390 = 2818960) and refuses digits, three letters in a row, and reserved names before the server sees them. Tofu Worldview lets the server decide, so that function is made to return CHAR_NAME_SUCCESS (0x57) at once: 55 8B EC 8B 45 08 becomes B8 57 00 00 00 C3 (mov eax, 0x57; ret), the same change mod-two-names documents. Only a Wow.exe with exactly the stock or the patched bytes there is touched, and the first change saves the original as Tofu/Wow.exe.original.
EXE="$WOW/Wow.exe"
NAME_OFF=2818960
name_bytes() { od -An -tx1 -j "$NAME_OFF" -N 6 "$EXE" 2>/dev/null | tr -d ' \n'; }
case "$(name_bytes)" in
  b857000000c3) ;;
  558bec8b4508)
    if { [ -f "$TOFU/Wow.exe.original" ] || cp -p "$EXE" "$TOFU/Wow.exe.original"; } && printf '\270\127\000\000\000\303' | dd of="$EXE" bs=1 seek="$NAME_OFF" conv=notrunc 2>/dev/null && [ "$(name_bytes)" = b857000000c3 ]; then
      say '  allowed numbers, repeated letters, and more in character names (Wow.exe updated; the original is in Tofu/Wow.exe.original)'
      CHANGED=1
    else
      warn 'Could not update Wow.exe to allow numbers in character names. Everything else works.'
    fi
    ;;
  *) say '  note: this Wow.exe is not the standard 3.3.5a build, so its name check was left alone (character names may be limited to letters).' ;;
esac

# ---- 6c. Wow.exe raid level check ----
# The stock 3.3.5a client (build 12340) refuses to send the convert-to-raid request when the player is below level 10: Script_ConvertToRaid at 0x574A00 does `cmp dword ptr [ecx+0xC0], 0xA` then `jl` (file offset 0x173E59 = 1523289, 83 B9 C0 00 00 00 0A 7C 3E). Tofu Worldview sets the raid level limit in worldserver.conf (Group.Raid.LevelRestriction), so the limit in the client is lowered to 1: the 0A becomes 01 and the check can never fail. Only a Wow.exe with exactly the stock or the patched bytes there is touched, and the first change saves the original as Tofu/Wow.exe.original. The matching button check in the UI is handled by the TofuRaidFix addon.
RAID_OFF=1523289
raid_bytes() { od -An -tx1 -j "$RAID_OFF" -N 9 "$EXE" 2>/dev/null | tr -d ' \n'; }
case "$(raid_bytes)" in
  83b9c0000000017c3e) ;;
  83b9c00000000a7c3e)
    if { [ -f "$TOFU/Wow.exe.original" ] || cp -p "$EXE" "$TOFU/Wow.exe.original"; } && printf '\001' | dd of="$EXE" bs=1 seek=$((RAID_OFF + 6)) conv=notrunc 2>/dev/null && [ "$(raid_bytes)" = 83b9c0000000017c3e ]; then
      say '  allowed players below level 10 to convert a group to a raid (Wow.exe updated; the original is in Tofu/Wow.exe.original)'
      CHANGED=1
    else
      warn 'Could not update Wow.exe to allow low-level raid groups. Everything else works.'
    fi
    ;;
  *) say '  note: this Wow.exe is not the standard 3.3.5a build, so its raid level check was left alone (raid groups may need level 10).' ;;
esac

# ---- 7. clean up ----
[ -d "$WOW/Tofu Patches" ] && rm -rf "$WOW/Tofu Patches" && say '  removed the old Tofu Patches folder'
# Cache holds the item, creature, and quest data the server sends; it is cleared at every launch so server-side changes (custom SQL with no new patch) always show (Chris, 2026-11-19).
if [ -d "$WOW/Cache" ]; then rm -rf "$WOW/Cache"; say '  cleared the Cache folder'; fi
printf 'Tofu Worldview patches, version %s\r\n' "$VERSION" > "$DATA/Tofu Patch Version.txt"
printf '%s\n' "$VERSION" > "$TOFU/version.txt"

if [ "$CHANGED" = 1 ]; then say "Updated to Tofu Worldview $VERSION."; else say "Up to date ($VERSION)."; fi
start_wow
exit 0
