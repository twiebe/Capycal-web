#!/bin/bash
# Build the package repositories from the newest releases, signed with a
# throwaway key, and install from them in Debian, Ubuntu and Fedora
# containers. Needs only Docker.
#
# The debs and the repository metadata come from a local server, the rpms
# from the GitHub releases, as for users.
set -euo pipefail
cd "$(dirname "$0")/.."

work=$PWD/.test-repos
net=capycal-test-repos
url=http://repo:8000/packages
count=${COUNT:-3}

cleanup() {
    docker rm -f capycal-test-repo >/dev/null 2>&1 || true
    docker network rm "$net" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup
rm -rf "$work"
mkdir -p "$work"

echo "== Building the repositories"
docker run --rm -e GH_TOKEN -e COUNT="$count" -e PACKAGES_URL="$url" \
    -v "$PWD/scripts":/scripts:ro -v "$work":/work debian:trixie bash -euc '
        apt-get update -qq
        apt-get install -qq -y --no-install-recommends apt-utils createrepo-c rpm gnupg curl jq ca-certificates >/dev/null
        export GNUPGHOME=$(mktemp -d)
        gpg --batch --quiet --passphrase "" --quick-gen-key "Capycal Test <test@capycal.app>" rsa4096 sign 1d
        /scripts/fetch-releases.sh /work/releases "$COUNT"
        /scripts/build-repos.sh /work/releases /work/site
        chown -R '"$(id -u):$(id -g)"' /work'

newest=$(ls "$work/releases" | sort -V | tail -n1)
oldest=$(ls "$work/releases" | sort -V | head -n1)
echo "== Releases: $(ls "$work/releases" | sort -V | tr '\n' ' ')"

docker network create "$net" >/dev/null
docker run -d --name capycal-test-repo --network "$net" --network-alias repo \
    -v "$work/site":/site:ro python:3.13-alpine python -m http.server -d /site 8000 >/dev/null
until docker exec capycal-test-repo python -c \
    "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/packages/capycal.asc')" 2>/dev/null; do
    sleep 0.2
done

for image in debian:trixie ubuntu:24.04; do
    echo "== $image"
    docker run --rm --network "$net" -v "$work/site/packages/capycal.asc":/capycal.asc:ro \
        "$image" bash -euc '
            mkdir -p /etc/apt/keyrings
            cp /capycal.asc /etc/apt/keyrings/capycal.asc
            echo "deb [signed-by=/etc/apt/keyrings/capycal.asc] '"$url"'/apt stable main" >/etc/apt/sources.list.d/capycal.list
            apt-get update >/tmp/update.log 2>&1 || { cat /tmp/update.log; exit 1; }
            if grep -E "^(W|E):" /tmp/update.log; then exit 1; fi
            apt-get install -qq -y capycal >/dev/null
            capycal --version | grep -F "'"${newest#v}"'"
            apt-get install -qq -y --allow-downgrades capycal='"${oldest#v}"'-1 >/dev/null
            capycal --version | grep -F "'"${oldest#v}"'"
            apt-get install -qq -y --simulate capycal-app >/dev/null'
done

echo "== fedora:42"
docker run --rm --network "$net" fedora:42 bash -euc '
    curl -fsSLo /etc/yum.repos.d/capycal.repo '"$url"'/rpm/capycal.repo
    dnf install -q -y capycal
    capycal --version | grep -F "'"${newest#v}"'"
    dnf repoquery -q capycal-app | grep -F "capycal-app-0:'"${newest#v}"'"'

echo "== All installs passed"
