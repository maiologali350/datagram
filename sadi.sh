#!/bin/bash

# Sepolia Beacon Chain RPC Setup Script
# Run as root or with sudo privileges

set -e

# Configuration
USERNAME="beacon"
DATA_DIR="/var/lib/beacon"
LOG_DIR="/var/log/beacon"
CONFIG_DIR="/etc/beacon"
SERVICE_NAME="beacon"
CLIENT="lighthouse"  # Options: lighthouse, prysm, teku, nimbus
NETWORK="sepolia"
RPC_PORT="5052"
METRICS_PORT="5054"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    print_error "Please run as root or with sudo"
    exit 1
fi

# Update system
print_status "Updating system packages..."
apt update && apt upgrade -y

# Install dependencies
print_status "Installing dependencies..."
apt install -y curl wget git build-essential libssl-dev pkg-config \
    libgmp-dev libsecp256k1-dev jq ufw chrony

# Create user and directories
print_status "Creating system user and directories..."
if ! id "$USERNAME" &>/dev/null; then
    useradd --system --create-home --home-dir "$DATA_DIR" --shell /bin/false "$USERNAME"
fi

mkdir -p "$DATA_DIR" "$LOG_DIR" "$CONFIG_DIR"
chown -R "$USERNAME:$USERNAME" "$DATA_DIR" "$LOG_DIR" "$CONFIG_DIR"

# Install Rust (for Lighthouse)
if [ "$CLIENT" = "lighthouse" ]; then
    print_status "Installing Rust..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source $HOME/.cargo/env
fi

# Install Go (for Prysm)
if [ "$CLIENT" = "prysm" ]; then
    print_status "Installing Go..."
    wget https://go.dev/dl/go1.21.0.linux-amd64.tar.gz
    rm -rf /usr/local/go && tar -C /usr/local -xzf go1.21.0.linux-amd64.tar.gz
    echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
    source /etc/profile
fi

# Install Beacon client based on selection
case $CLIENT in
    "lighthouse")
        print_status "Installing Lighthouse..."
        cd /tmp
        git clone https://github.com/sigp/lighthouse.git
        cd lighthouse
        git checkout stable
        make
        cp target/release/lighthouse /usr/local/bin/
        chmod +x /usr/local/bin/lighthouse
        ;;
        
    "prysm")
        print_status "Installing Prysm..."
        mkdir -p /tmp/prysm && cd /tmp/prysm
        curl https://raw.githubusercontent.com/prysmaticlabs/prysm/master/prysm.sh --output prysm.sh
        chmod +x prysm.sh
        cp prysm.sh /usr/local/bin/prysm
        ;;
        
    "teku")
        print_status "Installing Teku..."
        wget -O /usr/local/bin/teku https://artifacts.consensys.net/public/teku/raw/names/teku.tar.gz/versions/23.9.0/teku-23.9.0.tar.gz
        tar -xzf /usr/local/bin/teku -C /usr/local/bin/
        chmod +x /usr/local/bin/teku
        ;;
        
    "nimbus")
        print_status "Installing Nimbus..."
        git clone https://github.com/status-im/nimbus-eth2.git
        cd nimbus-eth2
        make nimbus_beacon_node
        cp build/nimbus_beacon_node /usr/local/bin/
        ;;
esac

# Create configuration
print_status "Creating configuration..."
cat > "$CONFIG_DIR/config.yaml" << EOF
# Sepolia Beacon Chain Configuration
network: "$NETWORK"
data-dir: "$DATA_DIR"
http: true
http-address: "0.0.0.0"
http-port: $RPC_PORT
metrics: true
metrics-address: "0.0.0.0"
metrics-port: $METRICS_PORT
execution-endpoint: "http://localhost:8551"
jwt-secret: "/path/to/jwt/secret"  # Update this after setting up execution client
EOF

# Create systemd service
print_status "Creating systemd service..."
cat > "/etc/systemd/system/$SERVICE_NAME.service" << EOF
[Unit]
Description=Sepolia Beacon Chain Client ($CLIENT)
After=network.target
Wants=network.target

[Service]
User=$USERNAME
Group=$USERNAME
Type=simple
Restart=always
RestartSec=5
ExecStart=/usr/local/bin/$CLIENT beacon_node \\
    --network $NETWORK \\
    --datadir $DATA_DIR \\
    --http \\
    --http-address 0.0.0.0 \\
    --http-port $RPC_PORT \\
    --metrics \\
    --metrics-address 0.0.0.0 \\
    --metrics-port $METRICS_PORT \\
    --execution-endpoint http://localhost:8551 \\
    --jwt-secret /path/to/jwt/secret  # Update this

StandardOutput=append:$LOG_DIR/beacon.log
StandardError=append:$LOG_DIR/beacon-error.log

[Install]
WantedBy=multi-user.target
EOF

# Setup firewall
print_status "Configuring firewall..."
ufw allow 22/tcp comment 'SSH'
ufw allow $RPC_PORT/tcp comment 'Beacon RPC'
ufw allow $METRICS_PORT/tcp comment 'Beacon Metrics'
ufw allow 9000/tcp comment 'P2P Networking'
ufw allow 9000/udp comment 'P2P Networking'
ufw --force enable

# Enable and start service
print_status "Enabling and starting service..."
systemctl daemon-reload
systemctl enable $SERVICE_NAME
systemctl start $SERVICE_NAME

# Create monitoring script
print_status "Creating monitoring script..."
cat > "/usr/local/bin/monitor-beacon.sh" << 'EOF'
#!/bin/bash

SERVICE="beacon"
LOG_FILE="/var/log/beacon/monitor.log"

check_service() {
    if systemctl is-active --quiet $SERVICE; then
        echo "$(date): Service is running" >> $LOG_FILE
        return 0
    else
        echo "$(date): Service is not running. Restarting..." >> $LOG_FILE
        systemctl restart $SERVICE
        return 1
    fi
}

check_sync() {
    # This is a placeholder - implement actual sync check based on your client
    # For Lighthouse: curl http://localhost:5052/eth/v1/node/syncing
    echo "$(date): Sync check placeholder" >> $LOG_FILE
}

check_service
check_sync
EOF

chmod +x /usr/local/bin/monitor-beacon.sh

# Add to crontab for monitoring
(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/monitor-beacon.sh") | crontab -

print_status "Installation completed!"
print_warning "Important next steps:"
print_warning "1. Set up an Execution Client (Geth, Nethermind, etc.)"
print_warning "2. Configure JWT secret for auth between execution and consensus clients"
print_warning "3. Update the JWT path in the systemd service file"
print_warning "4. Check logs: journalctl -u $SERVICE_NAME -f"
print_warning "5. Monitor sync status"

echo -e "${GREEN}Beacon RPC endpoint will be available at: http://your-vps-ip:$RPC_PORT${NC}"
