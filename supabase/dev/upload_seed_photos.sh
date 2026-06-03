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
# Re-running is safe: each seeded profile's existing photo rows are deleted
# first, so you always end up with exactly one photo per profile. (Old storage
# files orphan harmlessly — see supabase/dev/reset.sql.)

# No `set -e`: we check each request's HTTP status and `continue` on failure, so
# one bad photo never aborts the rest. `-u` still catches unset vars.
set -uo pipefail

SUPABASE_URL="${SUPABASE_URL:-https://kegkaerpusgwgfjjrxha.supabase.co}"
KEY="${SUPABASE_SERVICE_ROLE_KEY:?Set SUPABASE_SERVICE_ROLE_KEY (dashboard -> Settings -> API -> service_role)}"
FOLDER="${1:?Usage: $0 /path/to/parent-folder (with men/ and women/ subfolders)}"
BUCKET="profile-photos"

upload_for_gender() {
  local gender="$1" subdir="$2" pin_name="${3:-}" pin_pos="${4:-}"
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

  # Optional: pin a specific photo to a 1-based position in the upload order
  # (so e.g. a known face lands on a known profile). Index-based loops avoid
  # the bash 3.2 set -u empty-array quirk.
  if [ -n "$pin_name" ] && [ -n "$pin_pos" ] && [ "${#photos[@]}" -gt 0 ]; then
    local kept=() pinned="" p m="${#photos[@]}"
    for (( p=0; p<m; p++ )); do
      if [ "$(basename "${photos[$p]}")" = "$pin_name" ]; then
        pinned="${photos[$p]}"
      else
        kept+=("${photos[$p]}")
      fi
    done
    if [ -n "$pinned" ]; then
      local result=() k n="${#kept[@]}" insert_at=$(( pin_pos - 1 ))
      for (( k=0; k<n; k++ )); do
        [ "$k" -eq "$insert_at" ] && result+=("$pinned")
        result+=("${kept[$k]}")
      done
      [ "$insert_at" -ge "$n" ] && result+=("$pinned")
      photos=("${result[@]}")
      echo "[$gender] pinned '$pin_name' to position $pin_pos."
    else
      echo "[$gender] note: pin '$pin_name' not found in $subdir/ — using plain sort."
    fi
  fi

  # Clean existing photo rows for these seeded profiles first, so re-running
  # gives exactly one photo each (no duplicates / leftover broken rows). The
  # old storage files orphan harmlessly. Targets only seeded users.
  if [ "${#ids[@]}" -gt 0 ]; then
    local id_list; id_list="$(IFS=,; echo "${ids[*]}")"
    curl -s -X DELETE \
      "$SUPABASE_URL/rest/v1/profile_photos?user_id=in.($id_list)" \
      -H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H "Prefer: return=minimal" >/dev/null
  fi

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

# Pin Kanyin.jpg to the 7th uploaded women photo (4th arg = position).
upload_for_gender female women "Kanyin.jpg" 7
upload_for_gender male men
echo "Done."
