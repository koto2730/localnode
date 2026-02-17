#!/bin/sh

# エラーが発生したら即座に停止するように設定
set -e

echo "=========================================="
echo "[CI_SCRIPTS] ROOT ci_scripts/ci_post_clone.sh"
echo "[CI_SCRIPTS] PWD: $(pwd)"
echo "=========================================="

# 1. Flutter SDKのクローン
git clone https://github.com/flutter/flutter.git --depth 1 -b stable $HOME/flutter
export PATH="$PATH:$HOME/flutter/bin"

# 2. プロジェクトルートに戻る（ci_scripts/ から1階層上）
cd ..

# 3. Flutter設定
flutter config --enable-macos-desktop
flutter precache --ios --macos
flutter pub get

# 4. CocoaPodsのインストール
if ! command -v pod &> /dev/null; then
    sudo gem install cocoapods
fi

# 5. プラットフォーム別にpod install
if [ -d "ios" ]; then
    cd ios
    pod install
    cd ..
fi

if [ -d "macos" ]; then
    cd macos
    pod install
    cd ..
fi