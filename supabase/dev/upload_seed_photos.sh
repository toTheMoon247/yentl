#!/usr/bin/env bash
#
# Dev-only: upload local photos to seeded profiles' storage using the
# authenticated Supabase CLI session (no service_role key needed).
#
# Two steps:
#   1. In the Studio SQL editor, run supabase/dev/seed_photo_rows.sql. It creates
#      the profile_photos rows and shows a manifest. Export that result as CSV
#      (Export -> CSV), e.g. to ~/Desktop/manifest.csv.
#   2. Run this script with the photos folder and that CSV:
#        ./supabase/dev/upload_seed_photos.sh "/path/to/script photos" ~/Desktop/manifest.csv
#
# The photos folder must contain women/ and men/ subfolders. Photos are paired
# with profiles by the manifest's per-gender ordinal (sorted filename order),
# so any count works — extra photos are unused, and ordinals past the available
# photos are skipped with a note.
#
# Re-running re-uploads to the same fixed paths (overwrites), which is fine.

set -uo pipefail

FOLDER="${1:?Usage: $0 <photos-folder> <manifest.csv>}"
MANIFEST="${2:?Usage: $0 <photos-folder> <manifest.csv>}"
BUCKET="profile-photos"

if ! command -v supabase >/dev/null 2>&1; then
  echo "supabase CLI not found on PATH." >&2; exit 1
fi
[ -f "$MANIFEST" ] || { echo "Manifest not found: $MANIFEST" >&2; exit 1; }

# Sorted photo lists per gender subfolder.
load_photos() {
  find "$1" -maxdepth 1 -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) 2>/dev/null | sort
}
WOMEN=(); while IFS= read -r f; do [ -n "$f" ] && WOMEN+=("$f"); done < <(load_photos "$FOLDER/women")
MEN=();   while IFS= read -r f; do [ -n "$f" ] && MEN+=("$f");   done < <(load_photos "$FOLDER/men")
echo "women photos: ${#WOMEN[@]}   men photos: ${#MEN[@]}"

ok=0; skip=0; fail=0
while IFS=, read -r gender ord path; do
  gender="$(echo "$gender" | tr -d '[:space:]\r')"
  ord="$(echo "$ord" | tr -d '[:space:]\r')"
  path="$(echo "$path" | tr -d '[:space:]\r')"
  [ "$gender" = "gender" ] && continue           # header row
  [ -z "$gender" ] && continue                   # blank line
  case "$ord" in (*[!0-9]*|'') continue;; esac    # not a number

  if [ "$gender" = "female" ]; then
    idx=$(( ord - 1 )); file="${WOMEN[$idx]:-}"
  else
    idx=$(( ord - 1 )); file="${MEN[$idx]:-}"
  fi

  if [ -z "$file" ]; then
    echo "  [$gender #$ord] no photo for this ordinal — skipping."
    skip=$(( skip + 1 )); continue
  fi

  ext="$(echo "${file##*.}" | tr '[:upper:]' '[:lower:]')"
  ct="image/jpeg"; [ "$ext" = "png" ] && ct="image/png"

  if supabase storage cp --linked --yes --content-type "$ct" \
       "$file" "ss:///$BUCKET/$path" >/dev/null 2>/tmp/yentl_cp_err; then
    echo "  [$gender #$ord] uploaded $(basename "$file") -> $path"
    ok=$(( ok + 1 ))
  else
    echo "  [$gender #$ord] FAILED: $(tr -d '\n' < /tmp/yentl_cp_err)"
    fail=$(( fail + 1 ))
  fi
done < "$MANIFEST"

echo "Done. uploaded=$ok skipped=$skip failed=$fail"
