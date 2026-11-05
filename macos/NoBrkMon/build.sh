#!/bin/bash
# Compila o Monitor de Nobreak como app nativo para Mac Apple Silicon.
# Requisito: Xcode Command Line Tools  ->  xcode-select --install
set -e
cd "$(dirname "$0")"

APP="NoBrkMon.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -parse-as-library -O \
  -target arm64-apple-macos13.0 \
  NobreakMonitor.swift \
  -o "$APP/Contents/MacOS/NoBrkMon"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>NoBrkMon</string>
  <key>CFBundleDisplayName</key><string>NoBrkMon</string>
  <key>CFBundleIdentifier</key><string>com.zapavtech.nobrkmon</string>
  <key>CFBundleExecutable</key><string>NoBrkMon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Consultar o nobreak (servidor NUT) na rede local.</string>
</dict>
</plist>
EOF

# Assinatura "ad-hoc" com requisito fixo (baseado no identificador do app, e não no hash do
# binário). Assim o macOS reconhece o app como o mesmo a cada recompilação e mantém a
# permissão de Rede Local já concedida.
codesign --force --deep --sign - \
  -r='designated => identifier "com.zapavtech.nobrkmon"' \
  "$APP" || echo "Aviso: assinatura falhou"

echo "Pronto: $(pwd)/$APP"
echo "Abrindo..."
open "$APP"
