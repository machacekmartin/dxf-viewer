# Publishing DXF Viewer

End-to-end runbook for shipping releases on **Gumroad** **without** the
Apple Developer Program. Sparkle still works for auto-update — it uses
its own EdDSA keypair, unrelated to Apple.

> If you ever decide to pay $99/yr for an Apple Developer membership,
> just set `SIGN_ID` and `NOTARY_KEYCHAIN_PROFILE` env vars in your shell
> and the existing `scripts/release.sh` will sign + notarize automatically.
> No code changes needed.

---

## Channels

| Channel              | Friction for users                                |
|----------------------|---------------------------------------------------|
| Gumroad *(primary)*  | Right-click → Open once on first launch (Gatekeeper). |
| GitHub Releases      | Same right-click → Open dance.                    |

---

## 0. One-time setup

### 0.1 Sparkle key pair (auto-update signing)
1. Add Sparkle to `Package.swift`:
   ```swift
   .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
   ```
   …and add `"Sparkle"` to the `.executableTarget`'s `dependencies`.
2. `swift package resolve`.
3. Generate the keypair (one-time):
   ```sh
   ./.build/checkouts/Sparkle/bin/generate_keys
   ```
4. Copy the printed **public key** into `Resources/Info.plist` →
   `SUPublicEDKey`. **Never** commit the private key — it stays in your
   login keychain.

### 0.2 Gumroad product
1. Sign in at <https://gumroad.com>.
2. Products → New product → "Classic digital product".
3. Name: "DXF Viewer". Pricing: your call.
4. Upload a placeholder DMG; you'll overwrite it each release.
5. In the product description, paste the **first-launch instructions**
   from `README.md` so buyers know about the Gatekeeper dance.
6. Copy the public Gumroad URL into `README.md`.

### 0.3 Sparkle appcast hosting (GitHub Pages)
1. Push a `gh-pages` branch containing `appcast.xml`.
2. Enable Pages: Settings → Pages → Branch `gh-pages` `/ (root)`.
3. Verify `https://machacekmartin.github.io/dxf-viewer/appcast.xml`
   matches `SUFeedURL` in `Resources/Info.plist`.

---

## 1. Every release

```sh
# 1. Bump version
#    Resources/Info.plist:
#      CFBundleShortVersionString → "1.1.0"
#      CFBundleVersion            → increment integer
#    CHANGELOG.md: move from [Unreleased] → [1.1.0] — yyyy-mm-dd

# 2. Build DMG + ZIP locally
bash scripts/release.sh
# → dist/DXFViewer-1.1.0.dmg  (ad-hoc signed)
# → dist/DXFViewer-1.1.0.zip

# 3. Or push a git tag — GitHub Actions does it for you
git tag v1.1.0
git push origin v1.1.0

# 4. Upload dist/DXFViewer-1.1.0.dmg to Gumroad
#    (replace the previous DMG on the product page).

# 5. Sparkle: sign the DMG and update the appcast
./.build/checkouts/Sparkle/bin/sign_update dist/DXFViewer-1.1.0.dmg
# → "sparkle:edSignature=…  length=…"
#
# Edit appcast.xml: add a new <item> at the top with:
#   - <sparkle:shortVersionString>1.1.0</sparkle:shortVersionString>
#   - <sparkle:version>(integer build)</sparkle:version>
#   - enclosure url = direct DMG URL (GitHub Release asset, public)
#   - sparkle:edSignature + length from sign_update output
# Push to gh-pages.
```

---

## 2. Pre-flight smoke test

On a fresh Mac (or a fresh user account):

1. Download the DMG from Gumroad.
2. Mount, drag to `/Applications`.
3. Double-click — Gatekeeper blocks. **Right-click → Open** — Gatekeeper
   now allows. This is expected. Document is in README.
4. Open a `.dxf` (use `examples/`).
5. Double-click a `.dxf` in Finder — DXF Viewer appears in "Open With".
6. File → Open Recent — your previous file shows.
7. Cmd-+ / Cmd-- / Cmd-0 — zoom commands respond.
8. DXF Viewer → Check for Updates… — reports "you're up to date" if
   Sparkle is wired.

---

## 3. The unavoidable trade-off

Without Apple notarization, **every Gumroad buyer** will see a "DXF
Viewer can't be opened because Apple cannot check it for malicious
software" dialog the first time. They have to:

1. Right-click DXFViewer.app → Open
2. Hit "Open" in the follow-up dialog

After that, the app launches normally for the rest of time. On newer
macOS versions where "Open Anyway" is in System Settings → Privacy &
Security, the dialog still appears once and a one-click button there
clears it.

This costs you some refund-prone buyers. If sales pick up enough to
justify $99/yr, switch on the Apple Dev path described in
[`README.md`](../README.md#system-requirements) → no user action ever
required.

---

## 4. Troubleshooting

- **"App is damaged and can't be opened"** — macOS sometimes shows this
  instead of the normal Gatekeeper dialog. Workaround for the user:
  ```sh
  xattr -dr com.apple.quarantine /Applications/DXFViewer.app
  ```
  Document this in your Gumroad product description.

- **Sparkle says "Update check failed"** — appcast URL not reachable, or
  the EdDSA public key in `Info.plist` doesn't match the key that signed
  the DMG.

- **Sparkle won't apply the update** — Sparkle 2.x removes quarantine
  itself after EdDSA verifies, so this should work even without Apple
  notarization. If it fails, check that the appcast `enclosure url`
  serves the **DMG** (not a zip-of-app-bundle).
