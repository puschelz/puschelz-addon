# Release Checklist

Use this for every addon release (`v0.13.1`, `v0.14.0`, ...).

## 1) Update version

1. Edit `Puschelz/Puschelz.toc`:
   - `## Version: x.y.z`
   - `## Interface: ...` for currently supported client builds.
   - Use in-game to get the current interface number:
     - `/run print(select(4, GetBuildInfo()))`
   - Keep all supported major client interfaces comma-separated (example: `110200,120000`).
2. Commit and push:

```bash
cd /home/nik/workspace/puschelz-addon
git add Puschelz/Puschelz.toc README.md RELEASE_CHECKLIST.md .pkgmeta Puschelz fixtures
git commit -m "Release prep vX.Y.Z"
git push origin main
```

## 2) Tag

```bash
cd /home/nik/workspace/puschelz-addon
git tag vX.Y.Z
git push origin vX.Y.Z
```

## 3) Publish GitHub release

```bash
cd /home/nik/workspace/puschelz-addon
gh release create vX.Y.Z \
  --repo puschelz/puschelz-addon \
  --target main \
  --title "vX.Y.Z" \
  --notes "Short release notes"
```

If `gh` fails due token/org policy, create the release manually in GitHub UI from tag `vX.Y.Z`.

## 4) Validate package

1. Confirm release exists on GitHub.
2. In WoWUp, refresh/update the addon.
3. In-game:
   - `/pz status`
   - open guild bank + `/reload`
   - confirm `WTF/Account/<ACCOUNT>/SavedVariables/Puschelz.lua` updated.
