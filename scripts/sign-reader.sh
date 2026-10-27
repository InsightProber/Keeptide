#!/bin/sh
# XCTest adds test-host entitlements to nested command-line targets. An inherited
# sandbox helper must carry only app-sandbox + inherit. Sign a temporary copy with
# the exact entitlement set, then embed it before the outer app is signed.
set -eu
reader="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/KeeptidePasteboardReader"
staged_reader="$TARGET_TEMP_DIR/KeeptidePasteboardReader"
cp "$BUILT_PRODUCTS_DIR/KeeptidePasteboardReader" "$staged_reader"
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ]; then
  /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
    --entitlements "$SRCROOT/Config/PasteboardReader.entitlements" \
    --timestamp=none "$staged_reader"
fi
mkdir -p "$(dirname "$reader")"
cp "$staged_reader" "$reader"
