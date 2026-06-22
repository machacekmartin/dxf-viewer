# Releasing a new version

Quick checklist for shipping `vX.Y.Z`. Replace `1.1.0` with the actual new
version in every step below.

> **Run every command in this file from the repo root**
> (`cd /Users/machacekmartin/Code/dxf-viewer`).
> Paths like `./.build/...` are relative.

---

## 1. Bump version

Edit `Resources/Info.plist`:

```xml
<key>CFBundleShortVersionString</key>
<string>1.1.0</string>          <!-- semver, shown to users -->
<key>CFBundleVersion</key>
<string>2</string>              <!-- monotonic integer, +1 each release -->
```

Edit `CHANGELOG.md`: move items from `[Unreleased]` to a new `[1.1.0] —
YYYY-MM-DD` section.

Commit:

```sh
git add Resources/Info.plist CHANGELOG.md
git commit -m "Release v1.1.0"
git push origin main
```

---

## 2. Build the DMG locally

```sh
bash scripts/release.sh
```

Produces:

- `dist/DXFViewer-1.1.0.dmg`
- `dist/DXFViewer-1.1.0.zip`

(Both are ad-hoc signed. Apple Developer not required.)

---

## 3. Tag + GitHub Release

```sh
git tag -a v1.1.0 -m "v1.1.0"
git push origin v1.1.0
```

The `release.yml` workflow runs on `macos-26`, rebuilds, and uploads the
DMG + ZIP as a GitHub Release.

**If the workflow is too slow or fails**, upload manually using the
locally-built artifacts:

```sh
gh release create v1.1.0 \
    --title "DXF Viewer 1.1.0" \
    --notes-file <(awk '/^## \[1\.1\.0\]/,/^## \[/' CHANGELOG.md | sed '$d') \
    dist/DXFViewer-1.1.0.dmg dist/DXFViewer-1.1.0.zip
```

Grab the public DMG URL — should be:

```
https://github.com/machacekmartin/dxf-viewer/releases/download/v1.1.0/DXFViewer-1.1.0.dmg
```

---

## 4. Sign the DMG for Sparkle

> **Sign the DMG GitHub serves, not the local one.** The `release.yml`
> workflow rebuilds the DMG on its own runner after the tag push, and
> overwrites the asset you uploaded in step 3. The hosted bytes differ
> from the local bytes (compression nonces, codesign timestamps), so a
> signature over the local file fails Sparkle's EdDSA check with
> *"improperly signed"*.

First wait for the workflow to finish, then download the hosted DMG and
sign that:

```sh
gh run watch                                  # wait for the release workflow
curl -sSL -o /tmp/DXFViewer-1.1.0.dmg \
    https://github.com/machacekmartin/dxf-viewer/releases/download/v1.1.0/DXFViewer-1.1.0.dmg
./.build/artifacts/sparkle/Sparkle/bin/sign_update /tmp/DXFViewer-1.1.0.dmg
```

macOS will prompt for keychain access — click **Allow** (or **Always
Allow** if you've already done that once).

Output line:

```
sparkle:edSignature="…base64…" length="2207272"
```

Keep that line handy for step 5. The `length` is the exact byte count
of the hosted DMG and **must** match — Sparkle re-downloads, checks both
length and signature, and refuses any mismatch.

---

## 5. Update the appcast on gh-pages

```sh
git checkout gh-pages
```

Edit `appcast.xml`: **prepend** a new `<item>` immediately after `<language>`,
before the existing 1.0.0 item. Template:

```xml
    <item>
      <title>Version 1.1.0</title>
      <pubDate>Sat, 12 Jul 2026 12:00:00 +0000</pubDate>          <!-- RFC 2822 -->
      <sparkle:version>2</sparkle:version>                        <!-- = CFBundleVersion -->
      <sparkle:shortVersionString>1.1.0</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
        <h2>1.1.0</h2>
        <p>One-line summary of the changes.</p>
      ]]></description>
      <enclosure
        url="https://github.com/machacekmartin/dxf-viewer/releases/download/v1.1.0/DXFViewer-1.1.0.dmg"
        sparkle:edSignature="PASTE_FROM_STEP_4"
        length="PASTE_FROM_STEP_4"
        type="application/octet-stream" />
    </item>
```

Commit & push:

```sh
git add appcast.xml
git commit -m "appcast: v1.1.0"
git push origin gh-pages
git checkout main
```

Sync the same change onto main so future devs see the latest known-good
appcast:

```sh
git checkout gh-pages -- appcast.xml
git add appcast.xml
git commit -m "appcast: sync v1.1.0 on main"
git push origin main
```

GitHub Pages re-deploys in ~30 seconds. Verify:

```sh
curl -sS https://machacekmartin.github.io/dxf-viewer/appcast.xml | head
```

---

## 6. Upload to Gumroad

1. Go to <https://machacekmartin.gumroad.com/l/dxf-viewer-macos> → **Edit**.
2. Replace the existing DMG with `dist/DXFViewer-1.1.0.dmg`.
3. (Optional) update the product description with the new changelog
   highlights.
4. **Save** and **Publish**.

---

## 7. Verify auto-update works

On a Mac with the **previous** version installed:

1. Quit DXF Viewer if it's running.
2. Launch it.
3. **DXF Viewer → Check for Updates…**
4. Sparkle should detect 1.1.0, show the changelog, offer **Install Update**.
5. Click → it downloads, EdDSA-verifies, replaces, relaunches.

If Sparkle reports an error:

- Live appcast not updated? `curl` the URL and check the signature is the
  new one (CDN can take a few minutes).
- Signature mismatch / *"improperly signed"*? You signed your local DMG
  instead of the one the `release.yml` workflow rebuilt and uploaded.
  See step 4 — always `curl` the hosted DMG and re-run `sign_update` on
  that file, then update the appcast.

---

## Quick checklist (copy into PR description)

- [ ] `CFBundleShortVersionString` bumped
- [ ] `CFBundleVersion` incremented
- [ ] `CHANGELOG.md` updated
- [ ] `bash scripts/release.sh` produces fresh DMG + ZIP
- [ ] `git tag vX.Y.Z` pushed
- [ ] GitHub Release published with both assets
- [ ] `gh run watch` until release.yml finishes (it overwrites the asset)
- [ ] `sign_update` run on the **hosted** DMG (curl'd from the release URL)
- [ ] `appcast.xml` prepended on `gh-pages` (and synced to `main`)
- [ ] Live appcast served from GitHub Pages
- [ ] Gumroad DMG replaced
- [ ] "Check for Updates…" verified on a prior install
