#!/bin/sh

# エラーが発生したら即座に停止するように設定
set -e

echo "=========================================="
echo "[CI_SCRIPTS] macos/ci_scripts/ci_post_clone.sh"
echo "[CI_SCRIPTS] PWD: $(pwd)"
echo "=========================================="

# 1. Flutter SDKのクローン
git clone https://github.com/flutter/flutter.git --depth 1 -b stable $HOME/flutter
export PATH="$PATH:$HOME/flutter/bin"

# 2. プロジェクトルートに戻ってFlutter設定
# ci_scripts の中から実行されるので、cd ../.. でルートに戻る
cd ../..
flutter config --enable-macos-desktop

# Flutter 3.32+ で SPM が default ON。Xcode project 側に SPM の配線が無いと
# SPM 対応プラグイン (device_info_plus 12.x など) が Pod に取り込まれず
# "Module 'XXX' not found" でビルドが落ちる。Pod-only モードに固定する。
flutter config --no-enable-swift-package-manager

flutter precache --macos
flutter pub get

# ephemeral ファイル（FlutterInputs.xcfilelist等）を生成
flutter build macos --config-only

# 3. CocoaPodsのインストール
if ! command -v pod &> /dev/null; then
    sudo gem install cocoapods
fi

# 4. Podのインストール
cd macos
pod install
