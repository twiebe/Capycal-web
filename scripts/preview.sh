#!/bin/sh
# Build the site with the Capycal book under /docs into _site and serve it,
# like the Pages workflow does. Fetches mdBook into .tools if it is missing.
# Usage: scripts/preview.sh <capycal repo> [port]
set -eu

capycal=${1:?usage: scripts/preview.sh <capycal repo> [port]}
port=${2:-8000}
root=$(cd "$(dirname "$0")/.." && pwd)
version=v0.5.4

mdbook=$(command -v mdbook || true)
if [ -z "$mdbook" ]; then
    case "$(uname -s)-$(uname -m)" in
        Darwin-arm64) target=aarch64-apple-darwin ;;
        Darwin-x86_64) target=x86_64-apple-darwin ;;
        Linux-aarch64 | Linux-arm64) target=aarch64-unknown-linux-musl ;;
        Linux-x86_64) target=x86_64-unknown-linux-musl ;;
        *) echo "no mdBook build for $(uname -sm)" >&2; exit 1 ;;
    esac
    mdbook=$root/.tools/mdbook-$version
    if [ ! -x "$mdbook" ]; then
        mkdir -p "$root/.tools"
        curl -sSfL "https://github.com/rust-lang/mdBook/releases/download/$version/mdbook-$version-$target.tar.gz" \
            | tar -xz -C "$root/.tools"
        mv "$root/.tools/mdbook" "$mdbook"
    fi
fi

site=$root/_site
rm -rf "$site"
mkdir -p "$site"
cp -R "$root/index.html" "$root/imprint.html" "$root/404.html" "$root/assets" "$site/"
"$mdbook" build "$capycal/docs" -d "$site/docs"

echo "Serving on http://localhost:$port/ (Ctrl-C to stop)"
exec python3 -m http.server "$port" --bind 0.0.0.0 -d "$site"
