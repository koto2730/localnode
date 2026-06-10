#!/bin/sh

# エラーが発生したら即座に停止するように設定
set -e

echo "=========================================="
echo "[CI_SCRIPTS] ios/ci_scripts/ci_post_clone.sh"
echo "[CI_SCRIPTS] PWD: $(pwd)"
echo "=========================================="

# 1. Flutter SDKのクローン
git clone https://github.com/flutter/flutter.git --depth 1 -b stable $HOME/flutter
export PATH="$PATH:$HOME/flutter/bin"

# 2. プロジェクトルートに戻ってFlutter設定
# ci_scripts の中から実行されるので、cd ../.. でルートに戻る
cd ../..

# Flutter 3.32+ で SPM が default ON になった。Xcode project 側に SPM の
# 配線が無いため、SPM 対応プラグイン (device_info_plus 12.x など) が
# Pod に取り込まれず "Module 'device_info_plus' not found" になる。
# Pod-only モードに固定して、全プラグインを従来通り CocoaPods 経由で統合する。
flutter config --no-enable-swift-package-manager

flutter precache --ios
flutter pub get

# 3. CocoaPodsのインストール
if ! command -v pod &> /dev/null; then
    sudo gem install cocoapods
fi

# 4. Podのインストール
cd ios
pod install
