#!/usr/bin/env bash
#
# Dev-only: upload local photos to the profile-photos bucket and attach one to
# each seeded profile (display_name like 'Test %'), so the seeded discovery
# cards show real images. Pairs photos with profiles in sorted order.
#
# Requires the SERVICE ROLE key (bypasses RLS — the seeded users never log in).
# Get it from: Supabase dashboard -> Project Settings -> API -> service_role.
# It is a SECRET: pass it via env, never commit it.
#
# Usage:
#   export SUPABASE_SERVICE_ROLE_KEY="eyJ..."
#   ./supabase/dev/upload_seed_photos.sh ~/path/to/photos
#
# Re-running adds another photo to each profile. To start clean first:
#   delete from public.profile_photos
#   where user_id in (select id from public.profiles where display_name like 'Test %');
# (Storage files are left orphaned but harmless — see supabase/dev/reset.sql.)

set -euo pipefail

SUPABASE_URL="${SUPABASE_URL:-https://kegkaerpusgwgfjjrxha.supabase.co}"
KEY="${SUPABASE_SERVICE_ROLE_KEY:?Set SUPABASE_SERVICE_ROLE_KEY (dashboard -> Settings -> API -> service_role)}"
FOLDER="${1:?Usage: $0 /path/to/photos}"
BUCKET="profile-photos"

# 1) Seeded profile IDs, as CSV (skip the header row).
IDS=()
while IFS= read -r line; do
  [ -n "$line" ] && IDS+=("$line")
done < <(curl -s \
  "$SUPABASE_URL/rest/v1/profiles?select=id&display_name=like.Test*&order=display_name" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H "Accept: text/csv" \
  | tail -n +2 | tr -d '\r')

# 2) Local image files, sorted.
PHOTOS=()
while IFS= read -r f; do
  [ -n "$f" ] && PHOTOS+=("$f")
done < <(find "$FOLDER" -maxdepth 1 -type f \
  \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) | sort)

echo "Seeded profiles: ${#IDS[@]}   photos found: ${#PHOTOS[@]}"
COUNT=$(( ${#IDS[@]} < ${#PHOTOS[@]} ? ${#IDS[@]} : ${#PHOTOS[@]} ))
if [ "$COUNT" -eq 0 ]; then echo "Nothing to upload."; exit 0; fi
echo "Uploading $COUNT photo(s)..."

for (( i=0; i<COUNT; i++ )); do
  USER_ID="${IDS[$i]}"
  FILE="${PHOTOS[$i]}"
  EXT="$(echo "${FILE##*.}" | tr '[:upper:]' '[:lower:]')"
  case "$EXT" in
    png) CT="image/png" ;;
    *)   CT="image/jpeg" ;;
  esac
  PID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  OBJ_PATH="$USER_ID/$PID.$EXT"

  HTTP=$(curl -s -o /tmp/yentl_seed_upload.out -w "%{http_code}" \
    -X POST "$SUPABASE_URL/storage/v1/object/$BUCKET/$OBJ_PATH" \
    -H "Authorization: Bearer $KEY" -H "Content-Type: $CT" -H "x-upsert: true" \
    --data-binary "@$FILE")
  if [ "$HTTP" != "200" ]; then
    echo "  [$((i+1))/$COUNT] upload FAILED ($HTTP): $(cat /tmp/yentl_seed_upload.out)"
    continue
  fi

  HTTP=$(curl -s -o /tmp/yentl_seed_row.out -w "%{http_code}" \
    -X POST "$SUPABASE_URL/rest/v1/profile_photos" \
    -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
    -H "Content-Type: application/json" -H "Prefer: return=minimal" \
    -d "{\"id\":\"$PID\",\"user_id\":\"$USER_ID\",\"storage_path\":\"$OBJ_PATH\",\"order_index\":0}")
  if [ "$HTTP" != "201" ]; then
    echo "  [$((i+1))/$COUNT] row insert FAILED ($HTTP): $(cat /tmp/yentl_seed_row.out)"
    continue
  fi

  echo "  [$((i+1))/$COUNT] $USER_ID  <-  $(basename "$FILE")"
done

echo "Done."
