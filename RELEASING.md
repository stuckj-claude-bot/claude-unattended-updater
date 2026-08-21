# Releasing

## Cut a release

```bash
git tag v0.1.0
git push origin v0.1.0
```

The [Release workflow](.github/workflows/release.yml) builds the `.deb` and the signed `.rpm` from
[nfpm.yaml](nfpm.yaml), checks the package actually contains the binary and the
timer, and creates the GitHub release with the package attached. Publishing the
release then triggers the [package repositories workflow](.github/workflows/package-repos.yml), which
rebuilds the repository from *all* releases and pushes it to `gh-pages`.

Version comes from the tag with the leading `v` stripped, so `v0.1.0` produces
`claude-unattended-updater_0.1.0_all.deb`.

## Do not rename the package asset

`dpkg-scanpackages --arch <arch>` selects files by the `*_all.deb` /
`*_<arch>.deb` **filename pattern**, not by the control file's `Architecture`
field. Renaming the asset makes every index come out empty. The build script
fails loudly if that happens, but the cause is not obvious from the error.

## RPM packages are signed in their header, not just in the metadata

`gpgcheck=1` verifies a signature embedded in the **package header**, added at
build time by nfpm's `rpm.signature` block. Signing only `repomd.xml` satisfies
`repo_gpgcheck=1` and nothing else — an rpm covered by signed metadata but
unsigned itself fails to install with "package is not signed".

An unsigned rpm is not an error at build time; `rpm --checksig` simply reports
`digests OK` instead of `digests signatures OK`. The release workflow greps for
`signatures OK` and fails the release when it is missing, and the repository
builder repeats the check before publishing.

Deb needs no equivalent: APT chains trust from the signed `Release` through
`Packages`' SHA256 to each `.deb`, and does not check per-package signatures.

## Signing

The APT `Release` file is signed with a key held in repository secrets:

| Secret | Contents |
|---|---|
| `GPG_PRIVATE_KEY` | Armored secret key |
| `GPG_PASSPHRASE` | Passphrase for that key |
| `GPG_KEY_ID` | 16-character long key id |

The public key is published at `gpg-key.asc`, both at the site root and inside
`apt/`. The build script verifies the signature with `gpgv` — the same tool apt
uses — before publishing, and refuses to publish an empty index or an empty
exported key.

## First-time setup

GitHub Pages must be serving the `gh-pages` branch. The branch is created by the
first successful APT workflow run; enable Pages for it afterwards under
**Settings → Pages**, or:

```bash
gh api -X POST repos/OWNER/REPO/pages -f source[branch]=gh-pages -f source[path]=/
```

## Rebuild without releasing

The repository is a pure function of the releases, so it can be rebuilt at any
time from the Actions tab (**Package repositories → Run workflow**), or locally:

```bash
GPG_KEY_ID=... GPG_PASSPHRASE=... ./scripts/build-package-repos.sh   # dry run
```

`DRY_RUN` defaults to `1`; publishing requires `DRY_RUN=0`.
