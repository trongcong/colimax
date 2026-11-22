# ColimaX Release Process

English · [Tiếng Việt](RELEASE.vi.md)

This guide is for whoever publishes a release, including people who have never shipped a macOS app before. Complete **One-time setup** first, then follow **Per-release process** for every release.

> ColimaX runs outside the App Sandbox (it needs to call `colima` and read the Docker socket), so it is **not distributed through the Mac App Store**. Distribution channel: a DMG on GitHub Releases (and a Homebrew cask later). For macOS to let users open the app without warnings, releases **must** be signed with a Developer ID and notarized by Apple.

## 0. Is the Apple Developer Program required?

It is not required, but it determines the installation experience:

| | Not enrolled (free) | Developer ID (99 USD/year) |
|---|---|---|
| Signing | Ad-hoc (`scripts/build-app.sh` default) | Developer ID + notarization (`scripts/release.sh`) |
| User downloads the DMG | Blocked by Gatekeeper; the user must open the app once, then go to **System Settings → Privacy & Security → Open Anyway** (macOS 15+ no longer supports right-click → Open), or run `xattr -dr com.apple.quarantine /Applications/ColimaX.app` | Opens immediately, no warning |
| Built from source | Not blocked (a locally built app has no quarantine flag) | Not blocked |
| Official Homebrew cask | Not suitable (Homebrew is tightening rules on non-notarized casks; check the current policy) | Suitable |
| Best for | Developer betas, internal use | Public releases |

**Recommendation:** internal or developer betas can ship as ad-hoc builds with the instructions in section 3.6; for the public 1.0.0 release, enroll for a Developer ID.

## 1. Concepts

| Term | Meaning |
|---|---|
| **Commit** | A saved point in the source history. Commit often; there is no need to wait until something is "done". |
| **Release** | A version users can download: a `vX.Y.Z` tag + a signed, notarized DMG on GitHub Releases. |
| **SemVer** | `MAJOR.MINOR.PATCH`. PATCH: bug fixes. MINOR: backward-compatible features. MAJOR: breaking changes. Pre-releases: `1.0.0-beta.1`. |
| **Developer ID Application** | The Apple certificate used to sign apps distributed outside the App Store. |
| **Notarize** | Apple automatically scans the signed file (a few minutes) and issues a "ticket". Without a ticket, Gatekeeper blocks the app. |
| **Staple** | Attaches the ticket to the file so it opens even when the user's Mac is offline. |
| **Gatekeeper** | The macOS mechanism that checks signature + ticket when opening an app downloaded from the Internet. |

Single source of the version: the [`VERSION`](../VERSION) file. Build number: auto-incremented (CI uses `github.run_number`).

## 2. One-time setup

### 2.1 Apple Developer Program

1. Enroll at developer.apple.com/programs (99 USD/year, individual or organization; organizations need a D-U-N-S number).
2. Note your **Team ID** (10 characters) from the Membership page.

### 2.2 Developer ID Application certificate

1. Open **Xcode → Settings → Accounts** and sign in with the developer account's Apple ID.
2. **Manage Certificates… → + → Developer ID Application**.
3. Verify:
   ```bash
   security find-identity -v -p codesigning
   # → "Developer ID Application: Your Name (TEAMID)"
   ```
   The quoted string is your `SIGN_IDENTITY`.
4. **Back up** the certificate: Keychain Access → My Certificates → right-click → Export (.p12, with a strong password). Store it in a password manager. Losing the private key means creating a new certificate.

### 2.3 Notarization credentials

**Developer machine** (stored in the Keychain, done once):
```bash
xcrun notarytool store-credentials colimax \
  --apple-id <apple-id-email> --team-id <TEAMID>
# enter an app-specific password created at appleid.apple.com → Sign-In and Security → App-Specific Passwords
```
Afterwards, use `NOTARY_PROFILE=colimax`.

**CI** (an API key is recommended instead of a password):
1. App Store Connect → Users and Access → Integrations → **App Store Connect API** → create a key with the *Developer* role.
2. Download the `.p8` file (it can be downloaded **only once**), and note the **Key ID** and **Issuer ID**.

### 2.4 GitHub repository

1. Create the repository (suggested name `colimax`) and push the `main` branch.
2. If the repository is not `trongcong/colimax`, update the URLs in `.github/ISSUE_TEMPLATE/config.yml` and `site/`.
3. **Settings → Code security → Private vulnerability reporting → Enable** (free private channel for vulnerability reports; see [SECURITY.md](../SECURITY.md)).
4. **Settings → Environments → New environment `release`**:
   - *Required reviewers*: yourself, so every release needs an explicit approval. Leave *Prevent self-review* off (a solo maintainer must be able to approve) and turn *Allow administrators to bypass* off, so the approval cannot be skipped.
   - *Deployment branches and tags*: *Selected branches and tags* → add the tag rule `v*.*.*`, the only ref the Release workflow runs on. No other branch or workflow can then use the signing secrets.
5. **Settings → Secrets and variables → Actions**: add secrets to the `release` environment:

   | Secret | Source |
   |---|---|
   | `MACOS_CERT_P12_BASE64` | `base64 -i DeveloperID.p12 \| pbcopy` |
   | `MACOS_CERT_PASSWORD` | the .p12 file password |
   | `SIGN_IDENTITY` | the string from step 2.2 |
   | `NOTARY_KEY_P8_BASE64` | `base64 -i AuthKey_XXXX.p8 \| pbcopy` |
   | `NOTARY_KEY_ID` | Key ID |
   | `NOTARY_ISSUER_ID` | Issuer ID |

   Optional variable: `BUNDLE_ID` (default `dev.colimax.ColimaX`).
6. **Settings → Branches**: protect `main` and require the **CI** check to pass before merging.

### 2.5 Domain and product page

The landing page lives in `site/` (`index.html` in English, `vi/index.html` in Vietnamese, one shared `style.css`; plain HTML, no build step). The **Pages** workflow (`.github/workflows/pages.yml`) publishes it whenever `site/` changes on `main`. Preview locally with `python3 -m http.server -d site 8000`. The screenshots in `site/img/` come from the demo fixtures, never from a real machine: after a visible UI change, run `scripts/site-screenshots.sh` (it launches each screen and asks you to click the window) and review the images before committing.

1. **Settings → Pages → Build and deployment → Source: GitHub Actions**, then run the **Pages** workflow once (or push a change under `site/`). The page is served at `https://<owner>.github.io/colimax/`. On the Free plan, Pages needs a public repository.
2. Register `colimax.dev` (the bundle ID `dev.colimax.ColimaX` matches this domain).
3. **Verify the domain first**: GitHub profile → Settings → Pages → *Add a domain*, then add the TXT record it shows. This stops anyone else from claiming the domain for their own Pages site.
4. **Repository Settings → Pages → Custom domain**: enter `colimax.dev` and save, *before* creating the DNS records. With an Actions deploy no `CNAME` file is needed; GitHub ignores one if present.
5. DNS at the registrar (remove any default parking records):

   | Host | Type | Value |
   |---|---|---|
   | `@` | A | `185.199.108.153`, `185.199.109.153`, `185.199.110.153`, `185.199.111.153` |
   | `@` | AAAA | `2606:50c0:8000::153`, `2606:50c0:8001::153`, `2606:50c0:8002::153`, `2606:50c0:8003::153` |
   | `www` | CNAME | `<owner>.github.io` (without the repository name) |

   Instead of the A / AAAA records, an ALIAS / ANAME record at `@` pointing to `<owner>.github.io` also works if the provider supports it. Do not add a wildcard record (`*.colimax.dev`).
6. Check with `dig colimax.dev +noall +answer -t A` (propagation can take up to 24 hours), then tick **Enforce HTTPS** once GitHub has issued the certificate. `.dev` is HSTS-preloaded, so browsers only open it over HTTPS: the page is unreachable until the certificate exists.
7. After the first signed release, change the primary button on both pages from "Build from source" to the DMG download.

## 3. Per-release process

### 3.1 Preparation (on a clean `main` branch)

- [ ] Every feature in this release is `Implemented` or `Verified` in [FEATURES.md](FEATURES.md); nothing is left `In Progress`.
- [ ] `WARNINGS_AS_ERRORS=1 scripts/dev-build.sh` → 0 warnings.
- [ ] `scripts/run-tests.sh --integration` on a machine with Colima → 0 failures.
- [ ] Manual UI check using the checklist in [TESTING.md](TESTING.md).
- [ ] Test on a **clean machine** or a new macOS user account (one that has never run ColimaX), on macOS 14 and on the latest macOS.
- [ ] Update `VERSION`.
- [ ] `CHANGELOG.md`: rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`.
- [ ] Commit: `chore(release): X.Y.Z`.

### 3.2 Beta before the final release (recommended for every MINOR/MAJOR release)

1. Set `VERSION` to `X.Y.Z-beta.1` and add a matching entry in the CHANGELOG.
2. Release as in 3.3; the workflow marks the release as a *pre-release* automatically when the version contains `-`.
3. Send it to 3–10 testers and collect bugs for 1–2 weeks.
4. Fix bugs → `beta.2`… → once stable, release `X.Y.Z`.

### 3.3 Releasing

**Option A: automated (recommended):**
```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```
The **Release** workflow runs: checks that the tag matches `VERSION` → unit tests → build → sign → notarize the app → DMG → notarize the DMG → creates a **draft** GitHub Release with the DMG + SHA-256 + release notes extracted from the CHANGELOG.

**Option B: manual, on a developer machine:**
```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=colimax scripts/release.sh
git tag vX.Y.Z && git push origin vX.Y.Z
gh release create vX.Y.Z build/ColimaX-X.Y.Z.dmg build/ColimaX-X.Y.Z.dmg.sha256 --draft --title "ColimaX X.Y.Z" --notes-file <notes.md>
```

### 3.4 Check the draft before publishing

- [ ] Download the DMG from the draft onto **another machine** (or remove the old copy) and open it in Finder.
- [ ] No Gatekeeper warning; additionally check:
  ```bash
  spctl --assess --type execute --verbose=2 /Applications/ColimaX.app
  # → accepted, source=Notarized Developer ID
  shasum -a 256 ColimaX-X.Y.Z.dmg   # must match the .sha256 file
  ```
- [ ] Open the app and do a quick run through Dashboard, Containers and Diagnostics.
- [ ] Click **Publish release**.

### 3.5 After the release

- [ ] Add a new `## [Unreleased]` section at the top of the CHANGELOG.
- [ ] Update [FEATURES.md](FEATURES.md) (Release column) if needed.
- [ ] Update the Homebrew cask (once a tap exists).
- [ ] Watch for new issues during the first 48 hours.

### 3.6 Releasing without a Developer ID (beta / internal)

```bash
scripts/build-app.sh          # ad-hoc signing
scripts/make-dmg.sh           # DMG + .sha256 (DMG is not signed)
```

Create a GitHub Release manually as a **pre-release**, attach the DMG + `.sha256`, and state clearly in the release notes:

> This build is not notarized by Apple. After dragging ColimaX into Applications, open it once, then go to **System Settings → Privacy & Security → Open Anyway**. Alternatively, run: `xattr -dr com.apple.quarantine /Applications/ColimaX.app`. Verify the checksum with: `shasum -a 256 ColimaX-X.Y.Z.dmg`.

The GitHub **Release** workflow requires the Developer ID secrets, so it cannot be used in this case.

## 4. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Users see "ColimaX is damaged / can't be opened" | The build is ad-hoc signed or not notarized. Only distribute builds produced by `scripts/release.sh`. |
| `notarytool` returns `Invalid` | Read the log printed by `scripts/notarize.sh`. Common causes: missing `--timestamp`, missing Hardened Runtime (the scripts already handle this), binary signed with the wrong identity. |
| `The signature does not include a secure timestamp` | Signed without `--timestamp`; use `scripts/build-app.sh` with a Developer ID `SIGN_IDENTITY`. |
| Workflow fails at the certificate import step | The base64 secret is wrong (extra line breaks) or the .p12 password is wrong. |
| Tag does not match `VERSION` | The workflow stops on purpose. Delete the tag (`git tag -d vX && git push origin :refs/tags/vX`), fix `VERSION`, and tag again. |

## 5. Hotfixes and withdrawing a bad release

- **Hotfix:** fix on `main` → bump PATCH (`1.0.1`) → release as usual. Never move a published tag.
- **Withdrawing a seriously broken release:** mark the release as a *pre-release* or edit its description to say clearly "Do not use this release; upgrade to X.Y.Z+1". Do not delete a release that people have already downloaded (checksum links and articles would break).
- **Leaked certificate / API key:** revoke it immediately on developer.apple.com / App Store Connect, create a new one, and update the secrets.

## 6. Next steps

- **In-app updates** (Sparkle, with an EdDSA key to sign updates): not scheduled yet; would need an exception to ADR-3 (no external dependencies) in [ARCHITECTURE.md](ARCHITECTURE.md).
- **Homebrew cask**: start with a personal tap; move to the official cask once there are enough users.
