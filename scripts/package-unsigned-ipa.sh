#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <path-to.app> <output-directory>" >&2
  exit 2
fi

app_path="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
output_dir="$2"

if [[ ! -d "$app_path" ]]; then
  echo "App bundle not found: $app_path" >&2
  exit 1
fi

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
payload_dir="$output_dir/Payload"
ipa_path="$output_dir/PenCamera-unsigned.ipa"
metadata_path="$output_dir/build-metadata.txt"

rm -rf "$payload_dir"
rm -f "$ipa_path" "$metadata_path"
mkdir -p "$payload_dir"
ditto "$app_path" "$payload_dir/$(basename "$app_path")"

if codesign --verify "$payload_dir/$(basename "$app_path")" >/dev/null 2>&1; then
  echo "Expected an unsigned app, but a valid signature was found." >&2
  exit 1
fi

(
  cd "$output_dir"
  /usr/bin/zip -qry "$(basename "$ipa_path")" Payload
)

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Info.plist")"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Info.plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Info.plist")"
checksum="$(shasum -a 256 "$ipa_path" | awk '{print $1}')"

{
  echo "artifact=PenCamera-unsigned.ipa"
  echo "bundle_id=$bundle_id"
  echo "version=$version"
  echo "build=$build_number"
  echo "sha256=$checksum"
  echo "signature=unsigned"
} > "$metadata_path"

rm -rf "$payload_dir"

echo "Created $ipa_path"
cat "$metadata_path"

