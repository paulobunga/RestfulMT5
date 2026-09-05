#!/usr/bin/env bash
set -e

export DISPLAY=:0
export WINEPREFIX=/root/.wine
export WINEARCH=win64

echo "Starting Xvfb virtual frame buffer..."
Xvfb :0 -screen 0 1024x768x24 > /dev/null 2>&1 &
sleep 1

echo "Starting Openbox window manager..."
openbox > /dev/null 2>&1 &
sleep 1

echo "Configuring VNC server..."
mkdir -p /root/.vnc
x11vnc -storepasswd "${VNC_PASSWORD:-root}" /root/.vnc/passwd
x11vnc -forever -shared -rfbauth /root/.vnc/passwd -rfbport 5900 -display :0 > /dev/null 2>&1 &

MT5_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5"
mkdir -p "${MT5_DIR}"

echo "Deploying MQL5 scripts, EA, and DLL libraries to MetaTrader 5 directory..."
if [ -d "/app/MQL5" ]; then
    cp -rf /app/MQL5 "${MT5_DIR}/"
fi

echo "Generating MetaTrader 5 startup configuration..."
/app/scripts/generate_config.sh "${MT5_DIR}"

if [ -f "${MT5_DIR}/terminal64.exe" ]; then
    echo "Starting MetaTrader 5 with RestApi EA..."
    exec wine "${MT5_DIR}/terminal64.exe" /portable "/config:C:\\Program Files\\MetaTrader 5\\config.ini"
else
    echo "========================================================================="
    echo "Notice: terminal64.exe was not found in ${MT5_DIR}."
    echo "Please place or mount MetaTrader 5 files into the mt5-data volume or directory."
    echo "Container is staying alive for VNC access at port 5900."
    echo "========================================================================="
    tail -f /dev/null
fi
