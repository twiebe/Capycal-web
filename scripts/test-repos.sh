#!/bin/bash
# Build the package repositories from the newest releases, signed with a
# throwaway key, and install from them in Debian, Ubuntu and Fedora
# containers. Needs only Docker. PLATFORM=linux/amd64 tests the other
# architecture (emulated).
#
# Everything comes from a local server, the rpms too: the test signs those
# of the newest release with packaging/linux/sign-rpms.sh of the Capycal
# checkout, as the release workflow does.
set -euo pipefail
cd "$(dirname "$0")/.."

work=$PWD/.test-repos
net=capycal-test-repos
url=http://repo:8000/packages
count=${COUNT:-3}
# The rpm signing script, and until a release ships AppStream metadata, that
capycal=$(realpath "${CAPYCAL:-../capycal}")
platform=(${PLATFORM:+--platform "$PLATFORM"})

cleanup() {
    docker rm -f capycal-test-repo >/dev/null 2>&1 || true
    docker network rm "$net" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup
rm -rf "$work"
mkdir -p "$work"

# The same tools as the Pages workflow on ubuntu-24.04. The build runs twice:
# without a new release, the RPM metadata must not change. /bad gets a
# tampered InRelease and an RPM repository of unsigned rpms, which must be
# refused.
echo "== Building the repositories"
docker run --rm -e GH_TOKEN -e COUNT="$count" -e PACKAGES_URL="$url" -e RPM_BASEURL=http://repo:8000/releases/ \
    -v "$PWD/scripts":/scripts:ro -v "$work":/work \
    -v "$capycal/packaging/linux/sign-rpms.sh":/sign-rpms.sh:ro \
    -v "$capycal/packaging/linux/app.capycal.metainfo.xml":/metainfo.xml:ro ubuntu:24.04 bash -euc '
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -qq -y --no-install-recommends apt-utils createrepo-c rpm appstream appstream-compose gnupg curl jq perl ca-certificates >/dev/null
        export GNUPGHOME=$(mktemp -d)
        gpg --batch --quiet --passphrase "" --quick-gen-key "Capycal Test <test@capycal.app>" rsa4096 sign 1d
        /scripts/fetch-releases.sh /work/releases "$COUNT"
        newest=$(ls /work/releases | sort -V | tail -n1)
        oldest=$(ls /work/releases | sort -V | head -n1)
        PACKAGES_GPG_KEY=$(gpg --armor --export-secret-keys) /sign-rpms.sh /work/releases/$newest
        for deb in /work/releases/$newest/capycal-app_*.deb; do
            dpkg-deb -c "$deb" | grep -q metainfo && continue
            rm -rf /tmp/deb
            dpkg-deb -R "$deb" /tmp/deb
            mkdir -p /tmp/deb/usr/share/metainfo
            sed -e "s/@VERSION@/${newest#v}/" -e "s/@DATE@/$(date -u +%F)/" /metainfo.xml \
                >/tmp/deb/usr/share/metainfo/app.capycal.metainfo.xml
            dpkg-deb -b /tmp/deb "$deb" >/dev/null
        done
        /scripts/build-repos.sh /work/releases /work/first
        /scripts/build-repos.sh /work/releases /work/site
        cmp /work/first/packages/rpm/repodata/repomd.xml /work/site/packages/rpm/repodata/repomd.xml
        rm -rf /work/first
        cp -al /work/releases /work/site/releases
        mkdir /work/site/bad
        cp -r /work/site/packages /work/site/bad/
        sed -i "s/^Origin: Capycal/Origin: Capycat/" /work/site/bad/packages/apt/dists/stable/InRelease
        rm -rf /work/site/bad/packages/rpm/repodata /tmp/unsigned
        mkdir /tmp/unsigned
        ln -s /work/releases/$oldest /tmp/unsigned/
        createrepo_c --quiet --baseurl http://repo:8000/releases/ -o /work/site/bad/packages/rpm /tmp/unsigned
        sed -i "s|/packages/rpm|/bad/packages/rpm|; s/^\[capycal\]/[capycal-bad]/" /work/site/bad/packages/rpm/capycal.repo
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
    echo "== $image ${PLATFORM:-}"
    docker run --rm "${platform[@]}" --network "$net" -v "$work/site/packages/capycal.asc":/capycal.asc:ro \
        "$image" bash -euc '
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq && apt-get install -qq -y appstream >/dev/null
            mkdir -p /etc/apt/keyrings
            cp /capycal.asc /etc/apt/keyrings/capycal.asc
            echo "deb [signed-by=/etc/apt/keyrings/capycal.asc] http://repo:8000/bad/packages/apt stable main" >/etc/apt/sources.list.d/capycal.list
            apt-get update >/tmp/update.log 2>&1 || true
            if ! grep -q "BADSIG\|signature" /tmp/update.log; then
                cat /tmp/update.log; echo "a tampered InRelease was accepted"; exit 1
            fi
            echo "deb [signed-by=/etc/apt/keyrings/capycal.asc] '"$url"'/apt stable main" >/etc/apt/sources.list.d/capycal.list
            apt-get update >/tmp/update.log 2>&1 || { cat /tmp/update.log; exit 1; }
            if grep -E "^(W|E):" /tmp/update.log; then exit 1; fi
            appstreamcli get app.capycal | grep -E "^(Name|Package):"
            apt-get install -qq -y capycal >/dev/null
            capycal --version | grep -F "'"${newest#v}"'"
            apt-get install -qq -y --allow-downgrades capycal='"${oldest#v}"'-1 >/dev/null
            capycal --version | grep -F "'"${oldest#v}"'"
            apt-get install -qq -y --simulate capycal-app >/dev/null'
done

echo "== fedora:42 ${PLATFORM:-}"
docker run --rm "${platform[@]}" --network "$net" fedora:42 bash -euc '
    curl -fsSLo /etc/yum.repos.d/capycal-bad.repo http://repo:8000/bad/packages/rpm/capycal.repo
    if dnf install -y --repo capycal-bad capycal >/tmp/install.log 2>&1; then
        cat /tmp/install.log; echo "an unsigned rpm was installed"; exit 1
    fi
    rm /etc/yum.repos.d/capycal-bad.repo
    curl -fsSLo /etc/yum.repos.d/capycal.repo '"$url"'/rpm/capycal.repo
    dnf install -q -y capycal >/dev/null
    capycal --version | grep -F "'"${newest#v}"'"
    dnf repoquery -q capycal-app | grep -F "capycal-app-0:'"${newest#v}"'"
    if dnf repoquery -q capycal | grep -F "'"${oldest#v}"'"; then
        echo "an unsigned rpm is in the repository"; exit 1
    fi
    # Software centers go through PackageKit, which needs D-Bus and polkit
    dnf install -q -y PackageKit polkit dbus-daemon appstream >/dev/null
    mkdir -p /run/dbus
    dbus-daemon --system --fork
    /usr/lib/polkit-1/polkitd --no-debug >/dev/null 2>&1 &
    /usr/libexec/packagekitd >/tmp/packagekit.log 2>&1 &
    sleep 3
    pkcon refresh force >/dev/null 2>&1 || { cat /tmp/packagekit.log; exit 1; }
    if grep -i "skipping refresh of capycal" /tmp/packagekit.log; then exit 1; fi
    appstreamcli get app.capycal 2>/dev/null | grep -E "^(Name|Package):"
    find /var/cache/swcatalog/icons -name app.capycal.png | grep -q .'

echo "== All installs passed"
