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

# APT
cp "${debs[@]}" "$out/apt/pool/main/"
cd "$out/apt"
for arch in amd64 arm64; do
    dir=dists/stable/main/binary-$arch
    mkdir -p "$dir"
    apt-ftparchive --arch "$arch" packages pool >"$dir/Packages"
    gzip -9kn "$dir/Packages"
done
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
