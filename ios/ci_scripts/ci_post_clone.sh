#!/bin/sh

# エラーが発生したら即座に停止するように設定
set -e

# 1. Flutter SDKのクローン
git clone https://github.com/flutter/flutter.git --depth 1 -b stable $HOME/flutter
export PATH="$PATH:$HOME/flutter/bin"

# 2. プロジェクトルートに戻ってpub get
# ci_scripts の中から実行されるので、cd .. でルートに戻る
cd ..
flutter pub get

# 3. CocoaPodsのインストール（Xcode Cloudはbrewが遅い場合があるので、gemを検討）
# すでに入っている場合はスキップ
if ! command -v pod &> /dev/null; then
    sudo gem install cocoapods
fi

# 4. Podのインストール
cd ios
pod install