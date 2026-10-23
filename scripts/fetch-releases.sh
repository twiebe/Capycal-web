#!/bin/bash
# Download the .deb and .rpm assets of the newest published releases of
# Capycal into <out-dir>/<tag>/. A release still missing either kind (its
# assets still uploading) is skipped.
#
# Usage: fetch-releases.sh <out-dir> [count]
set -euo pipefail

out=$1
count=${2:-3}
repo=${CAPYCAL_REPO:-twiebe/capycal}

auth=()
if [ -n "${GH_TOKEN:-}" ]; then
    auth=(-H "Authorization: Bearer $GH_TOKEN")
fi

releases=$(curl -fsSL "${auth[@]}" "https://api.github.com/repos/$repo/releases?per_page=30")
selected=$(jq -r --argjson count "$count" '
    [.[] | select((.draft or .prerelease) | not)
         | {tag: .tag_name, urls: [.assets[].browser_download_url | select(test("\\.(deb|rpm)$"))]}
         | select(any(.urls[]; endswith(".deb")) and any(.urls[]; endswith(".rpm")))]
    | .[:$count][] | .tag as $tag | .urls[] | "\($tag) \(.)"' <<<"$releases")

if [ -z "$selected" ]; then
    echo "no release of $repo has packages" >&2
    exit 1
fi

rm -rf "$out"
while read -r tag url; do
    mkdir -p "$out/$tag"
    curl -fsSL -o "$out/$tag/${url##*/}" "$url"
done <<<"$selected"
echo "Fetched $(wc -l <<<"$selected") packages of $(ls "$out" | sort -V | tr '\n' ' ')"
