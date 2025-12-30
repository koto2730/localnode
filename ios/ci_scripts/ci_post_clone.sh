#!/bin/sh

# 1. Flutter SDKのクローン（安定版）
git clone https://github.com/flutter/flutter.git --depth 1 -b stable $HOME/flutter
export PATH="$PATH:$HOME/flutter/bin"

# 2. プレフライントチェックと依存関係の解決
flutter doctor
flutter pub get

# 3. CocoaPodsのインストール
HOMEBREW_NO_AUTO_UPDATE=1 brew install cocoapods
cd ..
pod install