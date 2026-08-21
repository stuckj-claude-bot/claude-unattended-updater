#!/usr/bin/env bash
# Rebuild the published APT and YUM repositories from the GitHub releases.
#
# Every published package is derived from the releases, so running this twice
# produces the same repositories and running it after a release adds that
# release. Nothing reads gh-pages to decide what exists: a deleted release
# simply drops out.
#
# Unlike a project shipping large binaries, the packages here are a few
# kilobytes, so gh-pages carries the whole pool rather than only the current
# version. That keeps Filename resolution trivial — APT resolves it against the
# sources.list root, which is the Pages site.
#
# Everything is built under .repobuild/ before anything is published, so a
# failure while building leaves the live repositories untouched.
#
# Requires: gh (authenticated), curl, dpkg-scanpackages, createrepo_c, and gpg
# with the signing key imported and GPG_KEY_ID set. Publishing needs DRY_RUN=0.
set -euo pipefail

REPO="${GITHUB_REPOSITORY:-stuckj/claude-unattended-updater}"
PAGES_URL="${PAGES_URL:-https://${REPO%%/*}.github.io/${REPO##*/}}"
KEY="${GPG_KEY_ID:?GPG_KEY_ID must be set}"
SUITE="${SUITE:-stable}"
LABEL="${LABEL:-claude-unattended-updater}"
ARCHES="${ARCHES:-amd64 arm64 armhf i386}"
export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

# Defaulting to a dry run means inspecting the script locally, or typing the
# obvious DRY_RUN=true, cannot rewrite the live repositories.
DRY_RUN="${DRY_RUN:-1}"
[ "$DRY_RUN" = 0 ] || DRY_RUN=1

say() { printf '\n== %s\n' "$1"; }
die() { echo "FATAL: $*" >&2; exit 1; }

# The signing key is passphrase-protected, so every gpg call feeds it on fd 0.
gpg_do() {
  printf '%s' "${GPG_PASSPHRASE:-}" |
    gpg --batch --yes --armor --passphrase-fd 0 --pinentry-mode loopback \
        --local-user "$KEY" "$@"
}

WORK="$(pwd)/.repobuild"
rm -rf "$WORK"; mkdir -p "$WORK/pages/apt/pool/main" "$WORK/pages/yum"
cd "$WORK"

say "collect package assets from every release of $REPO"
mapfile -t urls < <(
  gh api --paginate "repos/$REPO/releases" \
    --jq '.[] | select(.draft|not) | select(.prerelease|not)
          | .assets[] | select((.name|endswith(".deb")) or (.name|endswith(".rpm")))
          | .browser_download_url'
)
[ "${#urls[@]}" -gt 0 ] || die "no .deb or .rpm assets found in any release of $REPO"
for u in "${urls[@]}"; do
  n="${u##*/}"
  case "$n" in
    *.deb) dest="pages/apt/pool/main/$n" ;;
    *.rpm) dest="pages/yum/$n" ;;
    *)     continue ;;
  esac
  curl -sSfL "$u" -o "$dest" || die "download failed: $u"
done
for f in pages/apt/pool/main/*.deb; do
  [ -e "$f" ] || continue
  dpkg-deb -c "$f" | grep -q 'usr/bin/claude-unattended-update' \
    || die "$(basename "$f") does not contain usr/bin/claude-unattended-update"
done
debs=$(find pages/apt/pool/main -name '*.deb' | wc -l)
rpms=$(find pages/yum -name '*.rpm' | wc -l)
echo "  $debs deb(s), $rpms rpm(s)"
[ "$debs" -gt 0 ] || die "no .deb assets found"

say "build APT indexes"
( cd pages/apt
  for a in $ARCHES; do
    mkdir -p "dists/$SUITE/main/binary-$a"
    # --arch matches the *_all.deb / *_<arch>.deb filename pattern, not the
    # control file's Architecture field. Renaming an asset away from nfpm's
    # default silently empties every index.
    dpkg-scanpackages --arch "$a" pool/main 2>/dev/null \
      > "dists/$SUITE/main/binary-$a/Packages"
    # dpkg-scanpackages exits 0 and writes nothing when nothing matches;
    # signing that would advertise an empty index with the run still green.
    grep -q '^Package:' "dists/$SUITE/main/binary-$a/Packages" \
      || die "$SUITE/$a index is empty — no package matched arch $a"
    # Sorting makes the index byte-reproducible; readdir order is not stable.
    python3 - "dists/$SUITE/main/binary-$a/Packages" <<'PY'
import sys
p = sys.argv[1]
stanzas = [s.strip("\n") for s in open(p).read().split("\n\n") if s.strip()]
stanzas.sort()
with open(p, "w") as fh:
    for s in stanzas:
        fh.write(s + "\n\n")
PY
    gzip -nkf "dists/$SUITE/main/binary-$a/Packages"   # -n: no mtime
    echo "  $a: $(grep -c '^Package:' "dists/$SUITE/main/binary-$a/Packages") entries"
  done

  ( cd "dists/$SUITE"
    files=()
    for a in $ARCHES; do
      files+=("main/binary-$a/Packages" "main/binary-$a/Packages.gz")
    done
    { echo "Origin: $LABEL"; echo "Label: $LABEL"
      echo "Suite: $SUITE"; echo "Codename: $SUITE"
      echo "Architectures: $ARCHES"; echo "Components: main"
      echo "Description: $LABEL APT repository"
      echo "Date: $(date -Ru)"; echo "SHA256:"
      for f in "${files[@]}"; do
        echo " $(sha256sum "$f" | awk '{print $1}') $(stat -c%s "$f") $f"
      done
    } > Release
    gpg_do --detach-sign -o Release.gpg Release
    gpg_do --clearsign   -o InRelease   Release ) )

if [ "$rpms" -gt 0 ]; then
  say "build YUM repodata"
  command -v createrepo_c >/dev/null || die "createrepo_c is required to publish the yum repository"
  createrepo_c --quiet pages/yum
  # repomd.xml.asc covers the metadata (repo_gpgcheck). The packages themselves
  # are signed in their headers at build time, which is what gpgcheck verifies —
  # signing metadata alone would leave every install failing "package not signed".
  gpg_do --detach-sign -o pages/yum/repodata/repomd.xml.asc pages/yum/repodata/repomd.xml
  echo "  $rpms rpm(s) indexed"
fi

# gpg exits 0 and writes nothing if the key id does not resolve, which would
# replace the key every documented install curls with an empty file.
gpg --batch --armor --export "$KEY" > pages/gpg-key.asc
[ -s pages/gpg-key.asc ] || die "exported public key is empty — is GPG_KEY_ID ($KEY) right?"
cp pages/gpg-key.asc pages/apt/gpg-key.asc

cat > pages/index.html <<HTML
<!doctype html><meta charset=utf-8><title>$LABEL package repositories</title>
<h1>$LABEL</h1>
<p>See <a href="https://github.com/$REPO">the repository</a> for installation instructions.</p>
HTML

say "verify the APT signature the way apt does"
gpg --batch --dearmor < pages/gpg-key.asc > "$WORK/verify.gpg"
D="pages/apt/dists/$SUITE"
gpgv --keyring "$WORK/verify.gpg" "$D/Release.gpg" "$D/Release" 2>&1 \
  | grep -q 'Good signature' || die "Release.gpg does not verify against the published key"
# apt fetches InRelease in preference to Release, so verify the file clients use.
gpgv --keyring "$WORK/verify.gpg" "$D/InRelease" 2>&1 \
  | grep -q 'Good signature' || die "InRelease does not verify against the published key"
echo "  Release.gpg and InRelease both verify"

if [ "$rpms" -gt 0 ]; then
  say "verify every rpm carries a header signature"
  if command -v rpm >/dev/null; then
    for f in pages/yum/*.rpm; do
      rpm --checksig "$f" 2>/dev/null | grep -q 'signatures OK' \
        || die "$(basename "$f") has no header signature; gpgcheck=1 would reject it"
    done
    echo "  all $rpms rpm(s) signed"
  else
    echo "  WARNING: rpm not installed, cannot verify header signatures here"
  fi
fi

if [ "$DRY_RUN" = 1 ]; then
  say "DRY RUN — built under $WORK/pages, publishing nothing"
  find pages -type f | sort | sed 's/^/    /'
  exit 0
fi

say "publish to gh-pages"
# Passing the token as a header keeps it out of ghp/.git/config.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="http.https://github.com/.extraheader"
GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)"
export GIT_CONFIG_VALUE_0
git clone --depth 1 --branch gh-pages \
  "https://github.com/${REPO}.git" ghp 2>/dev/null || {
    git clone --depth 1 "https://github.com/${REPO}.git" ghp
    ( cd ghp && git checkout --orphan gh-pages && git rm -rf . >/dev/null 2>&1 || true )
  }
# Replace only the paths this script owns; anything else on the branch survives.
rm -rf ghp/apt ghp/gpg-key.asc ghp/index.html
cp -r pages/apt pages/gpg-key.asc pages/index.html ghp/
if [ "$rpms" -gt 0 ]; then
  rm -rf ghp/yum
  cp -r pages/yum ghp/
elif [ -d ghp/yum ]; then
  echo "  no rpm assets in any release; leaving the published yum repository alone"
fi
cd ghp
git config user.name  "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add -A
if git diff --cached --quiet; then
  echo "  nothing changed"
else
  git commit -q -m "repos: rebuild from releases ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
  git push -q origin gh-pages
  echo "  published to $PAGES_URL"
fi
