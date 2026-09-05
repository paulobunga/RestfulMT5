# MetaTrader 5 REST API Server Dockerfile
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV DISPLAY=:0

# Install Wine, Xvfb, x11vnc, openbox, curl, and required dependencies
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        wine64 \
        wine32 \
        winbind \
        xvfb \
        x11vnc \
        openbox \
        net-tools \
        curl \
        ca-certificates \
        procps \
        dos2unix \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy repo MQL5 folder into container
COPY MQL5 /app/MQL5

# Copy scripts into container
COPY scripts /app/scripts
RUN chmod +x /app/scripts/*.sh && dos2unix /app/scripts/*.sh

# Default environment variables
ENV REST_PORT=6542
ENV REST_AUTH_TOKEN=your-secret-token
ENV VNC_PASSWORD=root
ENV MT5_LOGIN=""
ENV MT5_PASSWORD=""
ENV MT5_SERVER=""

EXPOSE 6542 5900

ENTRYPOINT ["/app/scripts/entrypoint.sh"]
