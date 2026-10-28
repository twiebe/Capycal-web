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

# RPM: locations are <tag>/<file>, relative to the release downloads. The
# metadata takes its times from the newest package, so a run without a new
# release writes the same repomd.xml: a cached signature still matches it.
# gzip, since older dnf and zypper cannot read zstd.
revision=$(find "$pkgs" -name '*.rpm' -printf '%T@\n' | sort -n | tail -n1 | cut -d. -f1)
createrepo_c --quiet --baseurl "https://github.com/$repo/releases/download/" \
    --general-compress-type gz --revision "$revision" --set-timestamp-to-revision \
    --outputdir "$out/rpm" "$pkgs"
if [ -n "$catalog" ]; then
    gzip -9n <"$catalog/capycal.xml" >"$catalog/appstream.xml.gz"
    tar_icons 64x64 "$catalog/appstream-icons-64x64"
    tar_icons 128x128 "$catalog/appstream-icons-128x128"
    for type in appstream appstream-icons-64x64 appstream-icons-128x128; do
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
gpgcheck=0
repo_gpgcheck=1
gpgkey=$url/capycal.asc
EOF

size_mb=$(du -sm "$out" | cut -f1)
echo "Package repositories: $size_mb MB in $out"
if [ "$size_mb" -gt "$max_mb" ]; then
    echo "the repositories are larger than $max_mb MB" >&2
    exit 1
fi
