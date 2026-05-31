#!/bin/bash
# Builds the Android APK without opening Android Studio
# Run this from Terminal: bash build_apk.sh

GRADLE=~/.gradle/wrapper/dists/gradle-8.4-bin/1w5dpkrfk8irigvoxmyhowfim/gradle-8.4/bin/gradle
PROJECT=~/Projects/Android_Connect/AndroidApp
APK_OUT=~/Projects/Android_Connect/AndroidApp/app/build/outputs/apk/debug/app-debug.apk

echo "Building Android Connect APK..."
cd "$PROJECT"
"$GRADLE" assembleDebug --no-daemon

if [ $? -eq 0 ]; then
    echo ""
    echo "✓ Build successful!"
    echo "  APK: $APK_OUT"
    echo ""
    echo "  → AirDrop it to your phone, or run:"
    echo "  adb install $APK_OUT"
else
    echo "✗ Build failed"
fi
