#!/bin/bash
# Build the signed APT and RPM repositories under <out-dir>/packages from the
# packages fetch-releases.sh put into <packages-dir>/<tag>/. Signs with the
# default key of $GNUPGHOME.
#
# The debs are copied into the APT pool. The rpms stay on GitHub: the RPM
# metadata points at the release assets, so the site only carries the debs.
#
# Usage: build-repos.sh <packages-dir> <out-dir>
set -euo pipefail
shopt -s nullglob

pkgs=$(realpath "$1")
out=$(realpath -m "$2/packages")
url=${PACKAGES_URL:-https://capycal.app/packages}
repo=${CAPYCAL_REPO:-twiebe/capycal}
# Where dnf downloads the rpms: <tag>/<file> below it
rpm_baseurl=${RPM_BASEURL:-https://github.com/$repo/releases/download/}
# Pages sites may hold 1 GB in all
max_mb=500

debs=("$pkgs"/*/*.deb)
rpms=("$pkgs"/*/*.rpm)
if [ ${#debs[@]} -eq 0 ] || [ ${#rpms[@]} -eq 0 ]; then
    echo "no packages in $pkgs" >&2
    exit 1
fi

rm -rf "$out"
mkdir -p "$out/apt/pool/main" "$out/rpm"
gpg --batch --yes --armor --export >"$out/capycal.asc"

# AppStream catalog: lets software centers list capycal-app before it is
# installed. Composed from the metainfo in the newest app deb; none before
# the first release that ships it.
newest=$(ls "$pkgs" | sort -V | tail -n1)
appdebs=("$pkgs/$newest"/capycal-app_*.deb)
catalog=$(mktemp -d)
if [ ${#appdebs[@]} -gt 0 ]; then
    dpkg-deb -x "${appdebs[0]}" "$catalog/root"
fi
if [ -d "$catalog/root/usr/share/metainfo" ]; then
    appstreamcli compose --no-net --origin=capycal --result-root="$catalog/out" "$catalog/root" >/dev/null
    # compose knows nothing of packages: name the one to install
    zcat "$catalog/out/usr/share/swcatalog/xml/capycal.xml.gz" | sed \
        -e 's|<components version="\([^"]*\)">|<components version="\1" origin="capycal">|' \
        -e 's|^\( *\)<id>app.capycal</id>|&\n\1<pkgname>capycal-app</pkgname>|' >"$catalog/capycal.xml"
    icons=$catalog/out/usr/share/swcatalog/icons/capycal
    # Writes <name>.tar and <name>.tar.gz
    tar_icons() {
        (cd "$icons/$1" && tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - -- *) >"$2.tar"
        gzip -9kn "$2.tar"
    }
else
    echo "No AppStream metadata in capycal-app $newest, the repositories go out without a catalog"
    rm -rf "$catalog"
    catalog=
fi

# APT
cp "${debs[@]}" "$out/apt/pool/main/"
cd "$out/apt"
for arch in amd64 arm64; do
    dir=dists/stable/main/binary-$arch
    mkdir -p "$dir"
    apt-ftparchive --arch "$arch" packages pool >"$dir/Packages"
    gzip -9kn "$dir/Packages"
    if [ -n "$catalog" ]; then
        mkdir -p dists/stable/main/dep11
        # apt only fetches them if Release names the uncompressed file too
        appstreamcli convert --format=yaml "$catalog/capycal.xml" "dists/stable/main/dep11/Components-$arch.yml"
        gzip -9kn "dists/stable/main/dep11/Components-$arch.yml"
    fi
done
if [ -n "$catalog" ]; then
    for size in 48x48 64x64 128x128; do
        tar_icons "$size" "dists/stable/main/dep11/icons-$size"
    done
fi
apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=Capycal \
    -o APT::FTPArchive::Release::Label=Capycal \
    -o APT::FTPArchive::Release::Suite=stable \
    -o APT::FTPArchive::Release::Codename=stable \
    -o APT::FTPArchive::Release::Components=main \
    -o "APT::FTPArchive::Release::Architectures=amd64 arm64" \
    release dists/stable >"$out/Release"
mv "$out/Release" dists/stable/Release
gpg --batch --yes --clearsign -o dists/stable/InRelease dists/stable/Release
gpg --batch --yes --armor --detach-sign -o dists/stable/Release.gpg dists/stable/Release

# RPM: dnf and PackageKit check each rpm against our key (gpgcheck), so only
# rpms signed with it go in; older releases have none. The metadata is not
# checked: PackageKit cannot import a key for that and would skip the
# repository. Locations are <tag>/<file>, relative to the release downloads.
# The metadata takes its times from the newest package, so a run without a
# new release writes the same repomd.xml. gzip, since older dnf and zypper
# cannot read zstd.
rpmdb=$(mktemp -d)
signed=$(mktemp -d)
rpmkeys --dbpath "$rpmdb" --import "$out/capycal.asc"
for rpm in "${rpms[@]}"; do
    if rpmkeys --dbpath "$rpmdb" --checksig "$rpm" 2>/dev/null | grep -q ': digests signatures OK$'; then
        tag=$(basename "$(dirname "$rpm")")
        mkdir -p "$signed/$tag"
        ln -s "$rpm" "$signed/$tag/"
    fi
done
echo "Signed rpms: $(find "$signed" -name '*.rpm' | wc -l) of ${#rpms[@]}"
revision=$(find "$pkgs" -name '*.rpm' -printf '%T@\n' | sort -n | tail -n1 | cut -d. -f1)
createrepo_c --quiet --baseurl "$rpm_baseurl" \
    --general-compress-type gz --revision "$revision" --set-timestamp-to-revision \
    --outputdir "$out/rpm" "$signed"
rm -rf "$rpmdb" "$signed"
if [ -n "$catalog" ]; then
    gzip -9n <"$catalog/capycal.xml" >"$catalog/appstream.xml.gz"
    tar_icons 64x64 "$catalog/appstream-icons-64x64"
    tar_icons 128x128 "$catalog/appstream-icons-128x128"
    # PackageKit's libdnf only reads this one: every size in a folder
    (cd "$icons" && tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - -- *) |
        gzip -9n >"$catalog/appstream-icons.tar.gz"
    for type in appstream appstream-icons appstream-icons-64x64 appstream-icons-128x128; do
        modifyrepo_c --mdtype="$type" --no-compress "$catalog/$type".*.gz "$out/rpm/repodata" >/dev/null
    done
    # modifyrepo_c stamps the current time
    sed -i "s|<timestamp>[0-9]*</timestamp>|<timestamp>$revision</timestamp>|" "$out/rpm/repodata/repomd.xml"
    rm -rf "$catalog"
fi
gpg --batch --yes --armor --detach-sign "$out/rpm/repodata/repomd.xml"
cat >"$out/rpm/capycal.repo" <<EOF
[capycal]
name=Capycal
baseurl=$url/rpm
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=$url/capycal.asc
EOF

# Flatpak: the bundles of the releases go into one OSTree repository, oldest
# first, so the branch ends at the newest. Importing keeps the commits the
# bundles carry, so a run without a new release changes nothing a client
# would update to. Software centers install from the .flatpakref; bundles
# installed by hand name the repository too (build-flatpak.sh).
bundles=()
for tag in $(ls "$pkgs" | sort -V); do
    bundles+=("$pkgs/$tag"/*.flatpak)
done
if [ ${#bundles[@]} -gt 0 ]; then
    key=$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')
    ostree init --mode=archive-z2 --repo="$out/flatpak"
    for bundle in "${bundles[@]}"; do
        flatpak build-import-bundle --gpg-sign="$key" "$out/flatpak" "$bundle" >/dev/null
    done
    flatpak build-update-repo --gpg-sign="$key" --title=Capycal --default-branch=stable \
        --generate-static-deltas "$out/flatpak" >/dev/null
    gpgkey=$(gpg --batch --export "$key" | base64 -w0)
    cat >"$out/capycal.flatpakrepo" <<EOF
[Flatpak Repo]
Title=Capycal
Url=$url/flatpak/
Homepage=https://capycal.app/
Comment=Calendar sync for Linux, macOS and servers
GPGKey=$gpgkey
EOF
    cat >"$out/app.capycal.Capycal.flatpakref" <<EOF
[Flatpak Ref]
Title=Capycal
Name=app.capycal.Capycal
Branch=stable
Url=$url/flatpak/
SuggestRemoteName=capycal
Homepage=https://capycal.app/
IsRuntime=false
RuntimeRepo=https://dl.flathub.org/repo/flathub.flatpakrepo
GPGKey=$gpgkey
EOF
    echo "Flatpak bundles: ${#bundles[@]}"
else
    echo "No Flatpak bundles in the releases, the site goes out without a Flatpak repository"
fi

size_mb=$(du -sm "$out" | cut -f1)
echo "Package repositories: $size_mb MB in $out"
if [ "$size_mb" -gt "$max_mb" ]; then
    echo "the repositories are larger than $max_mb MB" >&2
    exit 1
fi
