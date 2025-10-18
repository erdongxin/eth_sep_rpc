#!/bin/bash

set -e

echo "🚀 开始部署 Sepolia Geth + Lighthouse 节点..."
sleep 1

##############################################
# 阶段 1：准备环境
##############################################

echo "📦 更新系统环境..."
sudo apt update -y
sudo apt install -y curl wget tar openssl ufw jq

##############################################
# 阶段 2：安装最新 Geth
##############################################

echo "⚙️ 检查旧版 Geth..."
if command -v geth &>/dev/null; then
  OLD_VER=$(geth version | grep -m1 'Version' | awk '{print $2}')
  echo "🔄 检测到旧版本 Geth ($OLD_VER)，将替换为最新版..."
  sudo systemctl stop geth.service || true
fi

echo "📥 正在获取 Geth 最新版本下载链接..."
LATEST_GETH_URL=$(curl -s https://api.github.com/repos/ethereum/go-ethereum/releases/latest \
  | jq -r '.assets[] | select(.browser_download_url | contains("geth-linux-amd64")) | .browser_download_url')

if [[ -z "$LATEST_GETH_URL" ]]; then
  echo "❌ 无法获取 Geth 最新版本下载地址，请检查网络。"
  exit 1
fi

echo "⬇️ 下载 Geth..."
wget -q -O geth.tar.gz "$LATEST_GETH_URL"

echo "📦 解压并安装 Geth..."
tar -xzf geth.tar.gz
cd geth-linux-amd64-* || { echo "❌ 解压失败"; exit 1; }
sudo mv geth /usr/bin/geth
cd ..
rm -rf geth.tar.gz geth-linux-amd64-*

echo "✅ Geth 安装完成，版本信息："
geth version | head -n 5

##############################################
# 阶段 3：安装最新 Lighthouse
##############################################

echo "⚙️ 检查旧版 Lighthouse..."
if command -v lighthouse &>/dev/null; then
  OLD_LH_VER=$(lighthouse --version | awk '{print $2}')
  echo "🔄 检测到旧版本 Lighthouse ($OLD_LH_VER)，将替换为最新版..."
  sudo systemctl stop lighthouse-beacon.service || true
fi

echo "📥 获取 Lighthouse 最新版本下载链接..."
LATEST_LIGHTHOUSE_URL=$(curl -s https://api.github.com/repos/sigp/lighthouse/releases/latest \
  | jq -r '.assets[] | select(.browser_download_url | contains("x86_64-unknown-linux-gnu.tar.gz")) | .browser_download_url')

if [[ -z "$LATEST_LIGHTHOUSE_URL" ]]; then
  echo "❌ 无法获取 Lighthouse 最新版本下载地址，请检查网络。"
  exit 1
fi

echo "⬇️ 下载 Lighthouse..."
wget -q -O lighthouse.tar.gz "$LATEST_LIGHTHOUSE_URL"

echo "📦 解压并安装 Lighthouse..."
tar -xzf lighthouse.tar.gz
sudo mv lighthouse /usr/local/bin/
rm -f lighthouse.tar.gz

echo "✅ Lighthouse 安装完成，版本信息："
lighthouse --version

##############################################
# 阶段 4：创建数据目录与 JWT
##############################################

echo "📁 创建数据目录与 JWT..."
sudo mkdir -p /data/geth_sepolia /data/lighthouse_sepolia /data/jwt
if [[ ! -f /data/jwt/jwt.hex ]]; then
  echo -n "$(openssl rand -hex 32)" | sudo tee /data/jwt/jwt.hex >/dev/null
  sudo chmod 600 /data/jwt/jwt.hex
  echo "✅ JWT 文件已生成：/data/jwt/jwt.hex"
else
  echo "🔑 已检测到现有 JWT 文件：/data/jwt/jwt.hex"
fi

##############################################
# 阶段 5：创建 systemd 服务
##############################################

echo "⚙️ 创建 systemd 服务..."

# Geth 服务
sudo tee /etc/systemd/system/geth.service >/dev/null <<EOF
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
sudo tee /etc/systemd/system/lighthouse-beacon.service >/dev/null <<EOF
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
  --supernode

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl daemon-reexec

sudo systemctl enable geth.service
sudo systemctl enable lighthouse-beacon.service

sudo systemctl restart geth.service
sudo systemctl restart lighthouse-beacon.service

##############################################
# 阶段 6：配置防火墙
##############################################

echo "🔐 配置防火墙 (UFW)..."
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

##############################################
# 阶段 7：完成信息
##############################################

echo ""
echo "🎉 部署完成！节点已启动。"
echo ""
echo "🧠 当前版本信息："
echo "   → Geth: $(geth version | grep -m1 'Version')"
echo "   → Lighthouse: $(lighthouse --version)"
echo ""
echo "📊 查看日志："
echo "   sudo journalctl -fu geth.service"
echo "   sudo journalctl -fu lighthouse-beacon.service"
echo ""
echo "🔍 查看同步状态："
echo "   curl -X POST --data '{\"jsonrpc\":\"2.0\",\"method\":\"eth_syncing\",\"params\":[],\"id\":1}' -H 'Content-Type: application/json' localhost:8545"
echo "   curl http://127.0.0.1:5052/eth/v1/node/syncing"
echo ""
echo "✅ 如果 Geth 和 Lighthouse 都返回 false，则节点同步完成。"
echo ""
