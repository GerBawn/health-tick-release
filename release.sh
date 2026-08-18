#!/bin/bash
set -e
cd "$(dirname "$0")"

# Read version from Info.plist
VERSION=$(grep -A1 CFBundleShortVersionString Sources/Info.plist | tail -1 | sed 's/.*<string>\(.*\)<\/string>.*/\1/')
TAG="v${VERSION}"
REPO="lifedever/health-tick-release"
GITEE_REPO="lifedever/health-tick-release"

echo "=== HealthTick Release ${TAG} ==="
echo ""

# Check if tag already exists on remote
if git ls-remote --tags origin | grep -q "refs/tags/${TAG}$"; then
    echo "Error: tag ${TAG} already exists. Bump version in Sources/Info.plist first."
    exit 1
fi

# Release notes — defined up front because both the site feed (latest.json,
# committed before push) and the GitHub/Gitee releases consume them.
RELEASE_NOTES="## HealthTick ${TAG}

### ✨ 改进
- 设置里原来的「计划」标签页拆成「计时」和「作息」两页：「计时」管多久（工作/休息时长、每日目标、长休息、护眼模式），「作息」管什么时候（工作日、国家节假日、工作时段、免打扰），不用再在一页里滚很远

### 📦 下载
- **Apple Silicon (M1/M2/M3/M4)**: \`HealthTick-${TAG}-Apple-Silicon.dmg\`
- **Intel**: \`HealthTick-${TAG}-Intel.dmg\`

### 📥 安装方式
打开 \`.dmg\` 文件，将 HealthTick 拖入 Applications 文件夹。
首次打开请前往 **系统设置 → 隐私与安全性** 点击\"仍要打开\"。"

# Build for each architecture separately
echo "[1/7] Building binaries..."
swift build -c release --arch arm64
echo "  Built arm64"
swift build -c release --arch x86_64
echo "  Built x86_64"

# Package app bundles
echo "[2/7] Packaging apps..."
STAGE="/tmp/health-tick-release-${VERSION}"
rm -rf "$STAGE"

for label in Apple-Silicon Intel; do
    if [ "$label" = "Apple-Silicon" ]; then
        BIN=".build/arm64-apple-macosx/release/HealthTick"
    else
        BIN=".build/x86_64-apple-macosx/release/HealthTick"
    fi
    APP_DIR="${STAGE}/${label}/HealthTick.app/Contents"
    mkdir -p "$APP_DIR/MacOS" "$APP_DIR/Resources"
    cp "$BIN" "$APP_DIR/MacOS/"
    cp Sources/Info.plist "$APP_DIR/"
    if [ -d "Sources/Resources" ]; then
        cp -R Sources/Resources/* "$APP_DIR/Resources/"
    fi
    codesign --force --deep --sign - "${STAGE}/${label}/HealthTick.app"
done

# Create DMGs
echo "[3/7] Creating DMGs..."
for label in Apple-Silicon Intel; do
    DMG_NAME="HealthTick-${TAG}-${label}.dmg"
    DMG_DIR="${STAGE}/dmg-${label}"
    mkdir -p "$DMG_DIR"
    cp -R "${STAGE}/${label}/HealthTick.app" "$DMG_DIR/"
    ln -s /Applications "$DMG_DIR/Applications"
    hdiutil create -volname "HealthTick" -srcfolder "$DMG_DIR" -ov -format UDZO \
        "${STAGE}/${DMG_NAME}" -quiet
    echo "  Created ${DMG_NAME}"
done

# Sync the site download source — the in-app updater's PRIMARY feed.
# Skipping this leaves latest.json on the old version and no client ever
# sees the update. DMGs + checksums must come from THIS build's artifacts.
echo "[4/7] Updating site feed (docs/latest.json + docs/downloads)..."
rm -f docs/downloads/HealthTick-*.dmg
mkdir -p docs/downloads
cp "${STAGE}/HealthTick-${TAG}-Apple-Silicon.dmg" docs/downloads/
cp "${STAGE}/HealthTick-${TAG}-Intel.dmg" docs/downloads/
VERSION="$VERSION" TAG="$TAG" RELEASE_NOTES="$RELEASE_NOTES" python3 - <<'PYEOF'
import hashlib, json, os

version = os.environ["VERSION"]
tag = os.environ["TAG"]
# Feed notes: keep the feature/fix sections, drop the download/install
# boilerplate (the in-app dialog has its own download UI).
notes = os.environ["RELEASE_NOTES"].split("### 📦 下载")[0].strip()

def entry(label):
    name = f"HealthTick-{tag}-{label}.dmg"
    data = open(f"docs/downloads/{name}", "rb").read()
    return {
        "url": f"https://www.lifedever.com/health-tick-release/downloads/{name}",
        "size": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    }

feed = {
    "version": version,
    "notes_zh": notes,
    "notes_en": "",
    "downloads": {
        "Apple-Silicon": entry("Apple-Silicon"),
        "Intel": entry("Intel"),
    },
}
with open("docs/latest.json", "w") as f:
    json.dump(feed, f, ensure_ascii=False, indent=2)
print("  docs/latest.json ->", version)
PYEOF
# Consistency gate: feed sha256/size must match the DMGs on disk
swift Tests/test_update_checker.swift > /tmp/ht-feed-check.log 2>&1 || {
    echo "Error: feed consistency tests failed"; tail -20 /tmp/ht-feed-check.log; exit 1; }
echo "  Feed consistency tests passed"

# Git commit, tag, push
echo "[5/7] Pushing tag ${TAG}..."
git add -A
git diff --cached --quiet || git commit -m "${TAG}"
git tag "$TAG" 2>/dev/null || true
# Push only main + the new tag — never `--tags`, which would try to push every
# local tag and abort the release if any stale local tag conflicts with remote.
git push origin main "$TAG"
git push gitee main "$TAG" 2>/dev/null || echo "  Warning: failed to push to Gitee remote"

# Upload to GitHub release repo
echo "[6/7] Publishing release to GitHub ${REPO}..."
gh release create "$TAG" \
    --repo "$REPO" \
    --title "HealthTick ${TAG}" \
    --notes "$RELEASE_NOTES" \
    "${STAGE}/HealthTick-${TAG}-Apple-Silicon.dmg" \
    "${STAGE}/HealthTick-${TAG}-Intel.dmg"

echo "  GitHub release done"

# Upload to Gitee release repo
echo "[7/7] Publishing release to Gitee ${GITEE_REPO}..."
if [ -n "$GITEE_TOKEN" ]; then
    # Gitee v5 auth: access_token in the request body / form field ("Authorization:
    # token" headers return an HTML error page). JSON is built with python so the
    # multi-line release notes get escaped properly.
    GITEE_RELEASE_ID=$(RELEASE_NOTES="$RELEASE_NOTES" TAG="$TAG" GITEE_REPO="$GITEE_REPO" python3 - <<'PYEOF'
import json, os, urllib.request
data = json.dumps({
    "access_token": os.environ["GITEE_TOKEN"],
    "tag_name": os.environ["TAG"],
    "name": "HealthTick " + os.environ["TAG"],
    "body": os.environ["RELEASE_NOTES"],
    "target_commitish": "main",
}).encode()
req = urllib.request.Request(
    "https://gitee.com/api/v5/repos/" + os.environ["GITEE_REPO"] + "/releases",
    data=data, headers={"Content-Type": "application/json"})
try:
    print(json.load(urllib.request.urlopen(req)).get("id", ""))
except Exception:
    print("")
PYEOF
)

    if [ -n "$GITEE_RELEASE_ID" ]; then
        for label in Apple-Silicon Intel; do
            DMG_FILE="${STAGE}/HealthTick-${TAG}-${label}.dmg"
            curl -s -X POST \
                "https://gitee.com/api/v5/repos/${GITEE_REPO}/releases/${GITEE_RELEASE_ID}/attach_files" \
                -F "access_token=${GITEE_TOKEN}" \
                -F "file=@${DMG_FILE}" > /dev/null
            echo "  Uploaded HealthTick-${TAG}-${label}.dmg to Gitee"
        done
        echo "  Gitee release done"
    else
        echo "  Warning: Failed to create Gitee release"
    fi
else
    echo "  Skipped (no GITEE_TOKEN env var set)"
    echo "  To enable: export GITEE_TOKEN=your_gitee_personal_access_token"
fi

echo ""
echo "=== Done! Released ${TAG} ==="
echo "GitHub: https://github.com/${REPO}/releases/tag/${TAG}"
echo "Gitee:  https://gitee.com/${GITEE_REPO}/releases/tag/${TAG}"

# Cleanup
rm -rf "$STAGE"
