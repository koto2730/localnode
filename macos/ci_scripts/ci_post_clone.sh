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
flutter precache --macos
flutter pub get

# 3. CocoaPodsのインストール
if ! command -v pod &> /dev/null; then
    sudo gem install cocoapods
fi

# 4. Podのインストール
cd macos
pod install
