#!/bin/bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"
node macos/Tests/reader.test.cjs
# Each generator uses a non-persistent website data store and local fixtures.
for TEST in native-regression shortcuts-integration adjustments-integration progress-integration restore-integration import-progress-integration prefetch-integration; do
  node "macos/Tests/$TEST.cjs"
  case "$TEST" in
    native-regression) NAME=ReaderNativeRegression ;;
    shortcuts-integration) NAME=ReaderShortcutsIntegration ;;
    adjustments-integration) NAME=ReaderAdjustmentIntegration ;;
    progress-integration) NAME=ReaderProgressIntegration ;;
    restore-integration) NAME=ReaderRestoreIntegration ;;
    import-progress-integration) NAME=ReaderImportProgressIntegration ;;
    prefetch-integration) NAME=ReaderPrefetchIntegration ;;
  esac
  xcrun swiftc "/tmp/$NAME.swift" -module-cache-path /tmp/floatingreader-test-modules -o "/tmp/$NAME" -framework AppKit -framework WebKit -framework Vision
  "/tmp/$NAME"
done

# Verify fixed desktop capture with a separately resized tiny display window.
node macos/Tests/next-loader-integration.cjs --batch
xcrun swiftc /tmp/ReaderNextLoaderBatch.swift -module-cache-path /tmp/floatingreader-test-modules -o /tmp/ReaderNextLoaderBatch -framework AppKit -framework WebKit -framework Vision
/tmp/ReaderNextLoaderBatch

# Plain text may bypass OCR; custom fonts must retain the OCR path.
for MODE in plain custom-font; do
  node macos/Tests/next-loader-integration.cjs "--$MODE"
  case "$MODE" in
    plain) NAME=ReaderNextLoaderPlain ;;
    custom-font) NAME=ReaderNextLoaderCustom ;;
  esac
  xcrun swiftc "/tmp/$NAME.swift" -module-cache-path /tmp/floatingreader-test-modules -o "/tmp/$NAME" -framework AppKit -framework WebKit -framework Vision
  "/tmp/$NAME"
done

# Live page handoff, next-next preloading and bottom-triggered continuation.
for MODE in normal canvas dead-source pending; do
  case "$MODE" in
    normal) node macos/Tests/chapter-pipeline-integration.cjs; NAME=ReaderChapterPipelineIntegration ;;
    canvas) node macos/Tests/chapter-pipeline-integration.cjs --canvas; NAME=ReaderChapterCanvasPipeline ;;
    dead-source) node macos/Tests/chapter-pipeline-integration.cjs --dead-source; NAME=ReaderChapterDeadPipeline ;;
    pending) node macos/Tests/chapter-pipeline-integration.cjs --pending; NAME=ReaderChapterPendingPipeline ;;
  esac
  xcrun swiftc "/tmp/$NAME.swift" -module-cache-path /tmp/floatingreader-test-modules -o "/tmp/$NAME" -framework AppKit -framework WebKit -framework Vision
  "/tmp/$NAME"
done

# Delayed canvas painting must not make fixed paging skip unread source rows.
for MODE in normal delayed; do
  if [ "$MODE" = delayed ]; then
    node macos/Tests/seam-integration.cjs --delayed
    NAME=ReaderDelayedSeamIntegration
  else
    node macos/Tests/seam-integration.cjs
    NAME=ReaderSeamIntegration
  fi
  xcrun swiftc "/tmp/$NAME.swift" -module-cache-path /tmp/floatingreader-test-modules -o "/tmp/$NAME" -framework AppKit -framework WebKit -framework Vision
  "/tmp/$NAME"
done
