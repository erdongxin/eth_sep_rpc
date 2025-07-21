#!/bin/bash

set -e

echo "🚀 开始部署 Sepolia Geth + Lighthouse 节点..."

### 阶段 1：安装 Geth ###
echo "📦 安装 Geth..."

sudo apt update
sudo apt install -y software-properties-common
sudo add-apt-repository -y ppa:ethereum/ethereum
sudo apt update
sudo apt install -y geth

echo "✅ Geth 安装完成，版本信息："
geth version

### 阶段 2：创建数据目录 & 生成 JWT ###
echo "📁 创建数据目录 & 生成 JWT 密钥..."

sudo mkdir -p /data/geth_sepolia
sudo mkdir -p /data/lighthouse_sepolia
sudo mkdir -p /data/jwt
echo -n "$(openssl rand -hex 32)" | sudo tee /data/jwt/jwt.hex > /dev/null
sudo chmod 600 /data/jwt/jwt.hex

echo "✅ JWT 密钥已创建：/data/jwt/jwt.hex"

### 阶段 3：安装 Lighthouse ###
echo "📦 安装 Lighthouse..."

LATEST_LIGHTHOUSE_URL=$(curl -s https://api.github.com/repos/sigp/lighthouse/releases/latest | grep browser_download_url | grep 'x86_64-unknown-linux-gnu\.tar\.gz"' | cut -d '"' -f 4)

wget -O lighthouse.tar.gz "$LATEST_LIGHTHOUSE_URL"
tar -xzf lighthouse.tar.gz
sudo mv lighthouse /usr/local/bin/
rm -f lighthouse.tar.gz


echo "✅ Lighthouse 安装完成，版本信息："
lighthouse --version

### 阶段 4：创建 systemd 服务 ###
echo "⚙️ 创建 Geth 和 Lighthouse systemd 服务..."

# Geth 服务
sudo tee /etc/systemd/system/geth.service > /dev/null <<EOF
[Unit]
Description=Geth Sepolia Execution Layer Client
After=network.target
Wants=network.target

[Service]
User=root
Group=root
Type=simple
Restart=always
RestartSec=5
TimeoutStopSec=180
LimitNOFILE=65535

ExecStart=/usr/bin/geth \\
  --sepolia \\
  --datadir /data/geth_sepolia \\
  --http \\
  --http.addr 0.0.0.0 \\
  --http.port 8545 \\
  --http.api eth,net,web3,engine,txpool \\
  --http.vhosts "*" \\
  --ws \\
  --ws.addr 0.0.0.0 \\
  --ws.port 8546 \\
  --ws.origins "*" \\
  --ws.api eth,net,web3,engine,txpool \\
  --authrpc.addr 127.0.0.1 \\
  --authrpc.port 8551 \\
  --authrpc.vhosts "*" \\
  --authrpc.jwtsecret /data/jwt/jwt.hex \\
  --metrics \\
  --metrics.addr 127.0.0.1 \\
  --metrics.port 6060 \\
  --cache=2048 \\
  --maxpeers 50 \\
  --rpc.txfeecap 0

[Install]
WantedBy=multi-user.target
EOF

# Lighthouse 服务
sudo tee /etc/systemd/system/lighthouse-beacon.service > /dev/null <<EOF
[Unit]
Description=Lighthouse Sepolia Consensus Layer Client (Beacon Node)
After=network.target geth.service
Wants=network.target geth.service

[Service]
User=root
Group=root
Type=simple
Restart=always
RestartSec=5
TimeoutStopSec=180
LimitNOFILE=65535

ExecStart=/usr/local/bin/lighthouse beacon_node \\
  --network sepolia \\
  --datadir /data/lighthouse_sepolia \\
  --execution-endpoint http://127.0.0.1:8551 \\
  --execution-jwt /data/jwt/jwt.hex \\
  --http \\
  --http-address 0.0.0.0 \\
  --http-port 5052 \\
  --metrics \\
  --metrics-address 127.0.0.1 \\
  --metrics-port 5054 \\
  --checkpoint-sync-url https://sepolia.checkpoint-sync.ethpandaops.io/ \\
  --disable-upnp \\

[Install]
WantedBy=multi-user.target
EOF

# 设置系统全局文件数限制
sudo sed -i '/^root.*nofile/d' /etc/security/limits.conf
echo -e "root soft nofile 65535\nroot hard nofile 65535" | sudo tee -a /etc/security/limits.conf

# 确保 PAM 启用 limits
if ! grep -q "pam_limits.so" /etc/pam.d/common-session; then
  echo "session required pam_limits.so" | sudo tee -a /etc/pam.d/common-session
fi

echo "🔄 重新加载 systemd..."
sudo systemctl daemon-reload
sudo systemctl daemon-reexec


echo "✅ 启用并启动服务..."
sudo systemctl enable geth.service
sudo systemctl enable lighthouse-beacon.service
sudo systemctl start geth.service
sudo systemctl start lighthouse-beacon.service

### 阶段 5：配置防火墙 ###
echo "🔐 配置 UFW 防火墙..."

sudo ufw allow 22/tcp
sudo ufw allow 30303/tcp
sudo ufw allow 30303/udp
sudo ufw allow 9000/tcp
sudo ufw allow 9000/udp
sudo ufw allow 8545/tcp
sudo ufw allow 8546/tcp
sudo ufw allow 5052/tcp

sudo ufw --force enable
sudo ufw status verbose

echo "✅ 防火墙已配置"

### 完成 ###
echo -e "\n🎉 节点部署完成！您可以使用以下命令监控同步："
echo "  sudo journalctl -fu geth.service"
echo "  sudo journalctl -fu lighthouse-beacon.service"
echo -e "\n🔍 查询 Geth 同步状态："
echo "  geth attach http://127.0.0.1:8545"
echo "  > eth.syncing"
echo -e "\n🔍 查询 Lighthouse 同步状态："
echo "  curl http://127.0.0.1:5052/eth/v1/node/syncing"
