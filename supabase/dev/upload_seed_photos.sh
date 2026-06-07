#!/usr/bin/env bash
#
# Dev-only: upload local photos to the profile-photos bucket and attach one to
# each seeded profile, so the seeded discovery/decision cards show real images.
#
# Expects a parent folder containing two subfolders:
#   <folder>/women  -> attached to seeded FEMALE profiles
#   <folder>/men    -> attached to seeded MALE profiles
# Photos pair with profiles in sorted order, except `Kanyin.jpg` which is pinned
# to the profile named "Kanyin" (so her name and photo match).
#
# Seeds are found via the public.dev_seed_profiles view (email-based), so this
# works regardless of display names. Run supabase/dev/dev_seed_view.sql once to
# create it.
#
# Requires the SERVICE ROLE key (bypasses RLS — the seeded users never log in).
# Get it from: dashboard -> Project Settings -> API -> service_role. It's a
# SECRET: pass it via env, never commit it.
#
# Usage:
#   export SUPABASE_SERVICE_ROLE_KEY="eyJ..."
#   ./supabase/dev/upload_seed_photos.sh "/Users/me/Desktop/script photos"
#
# Re-running is safe: each seeded profile's existing photo rows are deleted
# first, so you always end up with exactly one photo per profile. (Old storage
# files orphan harmlessly — see supabase/dev/reset.sql.)

# No `set -e`: each request's HTTP status is checked and we `continue` on
# failure, so one bad photo never aborts the rest. `-u` still catches typos.
set -uo pipefail

SUPABASE_URL="${SUPABASE_URL:-https://kegkaerpusgwgfjjrxha.supabase.co}"
KEY="${SUPABASE_SERVICE_ROLE_KEY:?Set SUPABASE_SERVICE_ROLE_KEY (dashboard -> Settings -> API -> service_role)}"
FOLDER="${1:?Usage: $0 /path/to/parent-folder (with men/ and women/ subfolders)}"
BUCKET="profile-photos"

# Upload one photo to a profile (storage object + profile_photos row).
upload_one() {
  local user_id="$1" file="$2" tag="$3"
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
    echo "  [$tag] upload FAILED ($http): $(cat /tmp/yentl_seed_upload.out)"
    return
  fi

  http=$(curl -s -o /tmp/yentl_seed_row.out -w "%{http_code}" \
    -X POST "$SUPABASE_URL/rest/v1/profile_photos" \
    -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
    -H "Content-Type: application/json" -H "Prefer: return=minimal" \
    -d "{\"id\":\"$pid\",\"user_id\":\"$user_id\",\"storage_path\":\"$obj\",\"order_index\":0}")
  if [ "$http" != "201" ]; then
    echo "  [$tag] row insert FAILED ($http): $(cat /tmp/yentl_seed_row.out)"
    return
  fi
  echo "  [$tag] $user_id  <-  $(basename "$file")"
}

upload_for_gender() {
  local gender="$1" subdir="$2" pin_file="${3:-}" pin_name="${4:-}"
  local dir="$FOLDER/$subdir"
  if [ ! -d "$dir" ]; then
    echo "[$gender] no '$subdir' subfolder at '$dir' — skipping."
    return
  fi

  # Seeded profiles (id,display_name) for this gender, via the dev view.
  local ids=() names=() line id name
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    [ "$line" = "id,display_name" ] && continue   # header
    id="$(echo "${line%%,*}" | tr -d '[:space:]\r')"
    name="$(echo "${line#*,}" | tr -d '\r')"
    [ -z "$id" ] && continue
    ids+=("$id"); names+=("$name")
  done < <(curl -s \
    "$SUPABASE_URL/rest/v1/dev_seed_profiles?select=id,display_name&gender=eq.$gender&order=display_name" \
    -H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H "Accept: text/csv")

  # Local image files, sorted.
  local photos=() f
  while IFS= read -r f; do
    [ -n "$f" ] && photos+=("$f")
  done < <(find "$dir" -maxdepth 1 -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) | sort)

  # Clean existing photo rows for these seeds (idempotent re-runs).
  if [ "${#ids[@]}" -gt 0 ]; then
    local id_list; id_list="$(IFS=,; echo "${ids[*]}")"
    curl -s -X DELETE \
      "$SUPABASE_URL/rest/v1/profile_photos?user_id=in.($id_list)" \
      -H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H "Prefer: return=minimal" >/dev/null
  fi

  # Optional pin: attach a specific photo file to the profile of a given name.
  local pinned_id="" pinned_file="" x
  if [ -n "$pin_file" ] && [ -n "$pin_name" ]; then
    for (( x=0; x<${#names[@]}; x++ )); do
      [ "${names[$x]}" = "$pin_name" ] && { pinned_id="${ids[$x]}"; break; }
    done
    for (( x=0; x<${#photos[@]}; x++ )); do
      [ "$(basename "${photos[$x]}")" = "$pin_file" ] && { pinned_file="${photos[$x]}"; break; }
    done
    if [ -n "$pinned_id" ] && [ -n "$pinned_file" ]; then
      echo "[$gender] pinned '$pin_file' -> '$pin_name'."
    else
      echo "[$gender] note: pin '$pin_file' -> '$pin_name' not satisfiable; plain order."
      pinned_id=""; pinned_file=""
    fi
  fi

  # Build the pairing: pinned first, then the rest in order (excluding pinned).
  local pair_ids=() pair_files=() rem_ids=() rem_files=()
  if [ -n "$pinned_id" ]; then pair_ids+=("$pinned_id"); pair_files+=("$pinned_file"); fi
  for (( x=0; x<${#ids[@]}; x++ )); do
    [ "${ids[$x]}" != "$pinned_id" ] && rem_ids+=("${ids[$x]}")
  done
  for (( x=0; x<${#photos[@]}; x++ )); do
    [ "${photos[$x]}" != "$pinned_file" ] && rem_files+=("${photos[$x]}")
  done
  local rn=$(( ${#rem_ids[@]} < ${#rem_files[@]} ? ${#rem_ids[@]} : ${#rem_files[@]} ))
  for (( x=0; x<rn; x++ )); do pair_ids+=("${rem_ids[$x]}"); pair_files+=("${rem_files[$x]}"); done

  local total="${#pair_ids[@]}"
  echo "[$gender] profiles: ${#ids[@]}  photos: ${#photos[@]}  -> uploading $total"
  if [ "$total" -eq 0 ]; then echo "  nothing to upload for $gender."; return; fi

  for (( x=0; x<total; x++ )); do
    upload_one "${pair_ids[$x]}" "${pair_files[$x]}" "$gender $((x+1))/$total"
  done
}

upload_for_gender female women "Kanyin.jpg" "Kanyin"
upload_for_gender male men
echo "Done."
