#!/bin/bash
# Build the package repositories from the newest releases, signed with a
# throwaway key, and install from them in Debian, Ubuntu and Fedora
# containers. Needs only Docker. PLATFORM=linux/amd64 tests the other
# architecture (emulated).
#
# Everything comes from a local server, the rpms too: the test signs those
# of the newest release with packaging/linux/sign-rpms.sh of the Capycal
# checkout, as the release workflow does. Until the releases carry Flatpak
# bundles, the one `make dist-flatpak` left in the checkout's dist/ stands in
# for the newest release's (the Flatpak test is skipped without it).
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
    -v "$capycal/packaging/linux/app.capycal.metainfo.xml":/metainfo.xml:ro \
    -v "$capycal/dist":/dist:ro ubuntu:24.04 bash -euc '
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -qq -y --no-install-recommends apt-utils createrepo-c rpm appstream appstream-compose flatpak ostree gnupg curl jq perl ca-certificates >/dev/null
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
        arch=$(flatpak --default-arch)
        ref=app/app.capycal.Capycal/$arch/stable
        bundle=$(ls /dist/capycal-app-v*-$arch.flatpak 2>/dev/null | tail -n1 || true)
        if ! ls /work/releases/*/*.flatpak >/dev/null 2>&1 && [ -n "$bundle" ]; then
            cp "$bundle" /work/releases/$newest/
        fi
        /scripts/build-repos.sh /work/releases /work/first
        /scripts/build-repos.sh /work/releases /work/site
        cmp /work/first/packages/rpm/repodata/repomd.xml /work/site/packages/rpm/repodata/repomd.xml
        if [ -d /work/site/packages/flatpak ]; then
            # The same bundles give the same commit, so clients see no update
            [ "$(ostree --repo=/work/first/packages/flatpak rev-parse $ref)" = "$(ostree --repo=/work/site/packages/flatpak rev-parse $ref)" ]
            # The next release: a new commit of the same app in a newer release
            ostree init --mode=archive-z2 --repo=/tmp/next
            flatpak build-import-bundle /tmp/next /work/releases/$newest/*.flatpak >/dev/null
            flatpak build-commit-from --src-ref=$ref --subject=next /tmp/next $ref >/dev/null
            mkdir -p /work/releases-next/v99.0.0
            cp -al /work/releases/* /work/releases-next/
            flatpak build-bundle --arch=$arch /tmp/next /work/releases-next/v99.0.0/capycal-app-v99.0.0-$arch.flatpak app.capycal.Capycal stable
            /scripts/build-repos.sh /work/releases-next /work/next
            ostree --repo=/tmp/next rev-parse $ref >/work/next-commit
        fi
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
        -e IMAGE="$image" "$image" bash -euc '
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
            # The desktop app after 0.3.1 needs libadwaita 1.7: Debian 13, not Ubuntu 24.04
            if [ "$IMAGE" = debian:trixie ]; then
                apt-get install -qq -y --simulate capycal-app >/dev/null
            fi'
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

if [ -d "$work/site/packages/flatpak" ]; then
    echo "== Flatpak ${PLATFORM:-}"
    # Installs only the app (--no-deps): the GNOME runtime comes from Flathub
    docker run -d --name capycal-test-flatpak "${platform[@]}" --network "$net" --privileged fedora:42 sleep infinity >/dev/null
    trap 'docker rm -f capycal-test-flatpak >/dev/null 2>&1 || true; cleanup' EXIT
    flatpak_run() { docker exec capycal-test-flatpak bash -euc "$1"; }
    flatpak_run 'dnf install -q -y flatpak >/dev/null
        flatpak install --user --noninteractive --no-deps --from '"$url"'/app.capycal.Capycal.flatpakref >/dev/null
        flatpak info --user app.capycal.Capycal | grep -E "^ *(Version|Commit|Origin):"
        flatpak remote-info --user capycal app.capycal.Capycal >/dev/null'
    # A new release on the server: flatpak update moves to its commit
    mv "$work/site/packages" "$work/packages-old"
    mv "$work/next/packages" "$work/site/packages"
    flatpak_run 'flatpak update --user --noninteractive --no-deps app.capycal.Capycal >/dev/null
        flatpak info --user app.capycal.Capycal | grep -F "'"$(cut -c1-12 "$work/next-commit")"'"'
fi

echo "== All installs passed"
