#!/usr/bin/env bash
set -e

MT5_DIR="${1:-/root/.wine/drive_c/Program Files/MetaTrader 5}"
CONFIG_FILE="${MT5_DIR}/config.ini"
PRESET_DIR="${MT5_DIR}/MQL5/Presets"
PRESET_FILE="${PRESET_DIR}/RestApi.set"

mkdir -p "${PRESET_DIR}"

# Generate Expert Advisor preset file (.set)
cat <<EOF > "${PRESET_FILE}"
host=http://0.0.0.0
port=${REST_PORT:-6542}
AuthToken=${REST_AUTH_TOKEN:-your-secret-token}
EOF

# Convert preset file to CRLF line endings for Windows/Wine
sed -i 's/$/\r/' "${PRESET_FILE}"

# Generate MT5 startup configuration file (config.ini)
cat <<EOF > "${CONFIG_FILE}"
[Common]
Login=${MT5_LOGIN}
Password=${MT5_PASSWORD}
Server=${MT5_SERVER}

[Experts]
AllowDllImport=1
Enabled=1
Account=1
Profile=1

[Startup]
Expert=Advisors\\RestApi
ExpertParameters=Presets\\RestApi.set
Symbol=EURUSD
Period=H1
EOF

# Convert config file to CRLF line endings for Windows/Wine
sed -i 's/$/\r/' "${CONFIG_FILE}"

echo "Configuration files generated at ${CONFIG_FILE} and ${PRESET_FILE}."
