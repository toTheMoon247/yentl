#!/usr/bin/env bash
#
# Dev-only: upload local photos to the profile-photos bucket and attach one to
# each seeded profile, so the seeded discovery cards show real images.
#
# Expects a parent folder containing two subfolders:
#   <folder>/women  -> attached to seeded FEMALE profiles
#   <folder>/men    -> attached to seeded MALE profiles
# Photos are paired with profiles in sorted filename order.
#
# Requires the SERVICE ROLE key (bypasses RLS — the seeded users never log in).
# Get it from: Supabase dashboard -> Project Settings -> API -> service_role.
# It is a SECRET: pass it via env, never commit it.
#
# Usage:
#   export SUPABASE_SERVICE_ROLE_KEY="eyJ..."
#   ./supabase/dev/upload_seed_photos.sh "/Users/me/Desktop/script photos"
#
# Re-running adds another photo to each profile. To start clean first:
#   delete from public.profile_photos
#   where user_id in (select id from public.profiles where display_name like 'Test %');
# (Storage files are left orphaned but harmless — see supabase/dev/reset.sql.)

# No `set -e`: we check each request's HTTP status and `continue` on failure, so
# one bad photo never aborts the rest. `-u` still catches unset vars.
set -uo pipefail

SUPABASE_URL="${SUPABASE_URL:-https://kegkaerpusgwgfjjrxha.supabase.co}"
KEY="${SUPABASE_SERVICE_ROLE_KEY:?Set SUPABASE_SERVICE_ROLE_KEY (dashboard -> Settings -> API -> service_role)}"
FOLDER="${1:?Usage: $0 /path/to/parent-folder (with men/ and women/ subfolders)}"
BUCKET="profile-photos"

upload_for_gender() {
  local gender="$1" subdir="$2"
  local dir="$FOLDER/$subdir"
  if [ ! -d "$dir" ]; then
    echo "[$gender] no '$subdir' subfolder at '$dir' — skipping."
    return
  fi

  # Seeded profile IDs of this gender (CSV, skip header).
  local ids=()
  while IFS= read -r line; do
    [ -n "$line" ] && ids+=("$line")
  done < <(curl -s \
    "$SUPABASE_URL/rest/v1/profiles?select=id&gender=eq.$gender&display_name=like.Test*&order=display_name" \
    -H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H "Accept: text/csv" \
    | tail -n +2 | tr -d '\r')

  # Local image files in the subfolder, sorted.
  local photos=()
  while IFS= read -r f; do
    [ -n "$f" ] && photos+=("$f")
  done < <(find "$dir" -maxdepth 1 -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) | sort)

  # Pair as many as possible — never assume exactly 20 of either.
  local count=$(( ${#ids[@]} < ${#photos[@]} ? ${#ids[@]} : ${#photos[@]} ))
  echo "[$gender] profiles: ${#ids[@]}  photos: ${#photos[@]}  -> uploading $count"
  if [ "${#photos[@]}" -gt "${#ids[@]}" ]; then
    echo "  note: $(( ${#photos[@]} - ${#ids[@]} )) extra $gender photo(s) ignored (only ${#ids[@]} profiles)."
  elif [ "${#photos[@]}" -lt "${#ids[@]}" ]; then
    echo "  note: $(( ${#ids[@]} - ${#photos[@]} )) $gender profile(s) will have no photo."
  fi
  if [ "$count" -eq 0 ]; then
    echo "  nothing to upload for $gender."
    return
  fi

  local i
  for (( i=0; i<count; i++ )); do
    local user_id="${ids[$i]}"
    local file="${photos[$i]}"
    local ext; ext="$(echo "${file##*.}" | tr '[:upper:]' '[:lower:]')"
    local ct="image/jpeg"; [ "$ext" = "png" ] && ct="image/png"
    local pid; pid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    local obj="$user_id/$pid.$ext"

    local http
    http=$(curl -s -o /tmp/yentl_seed_upload.out -w "%{http_code}" \
      -X POST "$SUPABASE_URL/storage/v1/object/$BUCKET/$obj" \
      -H "Authorization: Bearer $KEY" -H "Content-Type: $ct" -H "x-upsert: true" \
      --data-binary "@$file")
    if [ "$http" != "200" ]; then
      echo "  [$gender $((i+1))/$count] upload FAILED ($http): $(cat /tmp/yentl_seed_upload.out)"
      continue
    fi

    http=$(curl -s -o /tmp/yentl_seed_row.out -w "%{http_code}" \
      -X POST "$SUPABASE_URL/rest/v1/profile_photos" \
      -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
      -H "Content-Type: application/json" -H "Prefer: return=minimal" \
      -d "{\"id\":\"$pid\",\"user_id\":\"$user_id\",\"storage_path\":\"$obj\",\"order_index\":0}")
    if [ "$http" != "201" ]; then
      echo "  [$gender $((i+1))/$count] row insert FAILED ($http): $(cat /tmp/yentl_seed_row.out)"
      continue
    fi

    echo "  [$gender $((i+1))/$count] $user_id  <-  $(basename "$file")"
  done
}

upload_for_gender female women
upload_for_gender male men
echo "Done."
