#!/bin/bash

set -e

echo "🚀 开始部署 Sepolia Geth + Lighthouse 节点 + RPC 高并发优化..."
sleep 1

##############################################
# 阶段 0：停止现有服务
##############################################
sudo systemctl stop geth.service || true
sudo systemctl stop lighthouse-beacon.service || true
sudo systemctl stop nginx.service || true
sleep 5

##############################################
# 阶段 1：准备环境
##############################################
echo "📦 更新系统环境..."
sudo apt update -y
sudo apt install -y curl wget tar openssl ufw jq software-properties-common nginx

##############################################
# 阶段 2：安装/升级最新 Geth
##############################################
echo "⚙️ 检查 Geth 版本状态..."
if ! grep -q "ethereum/ethereum" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
  echo "➕ 添加 Ethereum 官方软件源..."
  sudo add-apt-repository -y ppa:ethereum/ethereum
fi
sudo apt update -y

if command -v geth &>/dev/null; then
  LOCAL_VER=$(geth version | grep -m1 'Version' | awk '{print $2}')
  REPO_VER=$(apt-cache policy geth | grep Candidate | awk '{print $2}')
  LOCAL_MAJOR=$(echo "$LOCAL_VER" | cut -d'-' -f1 | cut -d'+' -f1)
  REPO_MAJOR=$(echo "$REPO_VER" | cut -d'-' -f1 | cut -d'+' -f1)
  if [ "$REPO_MAJOR" != "$LOCAL_MAJOR" ] || dpkg --compare-versions "$REPO_VER" gt "$LOCAL_VER"; then
    echo "🔄 检测到新版可用，将升级..."
    sudo systemctl stop geth.service || true
    sudo apt install -y --only-upgrade geth
  else
    echo "✅ Geth 已是最新版本，无需升级。"
  fi
else
  echo "🆕 未检测到 Geth，将进行全新安装..."
  sudo apt install -y geth
fi

echo "✅ Geth 安装/升级完成：$(geth version | head -n 1)"

##############################################
# 阶段 3：安装 Lighthouse v8.0.0
##############################################
echo "📥 安装 Lighthouse v8.0.0 ..."
wget -q https://github.com/sigp/lighthouse/releases/download/v8.0.0/lighthouse-v8.0.0-x86_64-unknown-linux-gnu.tar.gz -O lighthouse.tar.gz

tar -xzf lighthouse.tar.gz
sudo mv lighthouse /usr/local/bin/lighthouse
sudo chmod +x /usr/local/bin/lighthouse
rm -f lighthouse.tar.gz

echo "✅ Lighthouse 安装完成：$(lighthouse --version)"

##############################################
# 阶段 4：创建数据目录与 JWT
##############################################
sudo mkdir -p /data/geth_sepolia /data/lighthouse_sepolia /data/jwt
if [[ ! -f /data/jwt/jwt.hex ]]; then
  echo -n "$(openssl rand -hex 32)" | sudo tee /data/jwt/jwt.hex >/dev/null
  sudo chmod 600 /data/jwt/jwt.hex
  echo "✅ JWT 文件生成：/data/jwt/jwt.hex"
else
  echo "🔑 JWT 文件已存在：/data/jwt/jwt.hex"
fi

##############################################
# 阶段 5：TCP 内核参数优化
##############################################
echo "⚙️ 配置 TCP 内核参数..."
sudo tee /etc/sysctl.d/99-tcp-tuning.conf >/dev/null <<EOF
net.core.somaxconn = 65535
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.core.netdev_max_backlog = 65535
EOF
sudo sysctl --system
echo "✅ TCP 内核优化完成"

##############################################
# 阶段 6：创建 systemd 服务
##############################################

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

ExecStart=/usr/bin/geth \
  --sepolia \
  --datadir /data/geth_sepolia \
  --syncmode snap \
  --http \
  --http.addr 0.0.0.0 \
  --http.port 8545 \
  --http.api eth,net,web3,engine,txpool \
  --http.vhosts "*" \
  --ws \
  --ws.addr 0.0.0.0 \
  --ws.port 8546 \
  --ws.api eth,net,web3,engine,txpool \
  --authrpc.addr 127.0.0.1 \
  --authrpc.port 8551 \
  --authrpc.vhosts "*" \
  --authrpc.jwtsecret /data/jwt/jwt.hex \
  --metrics \
  --metrics.addr 127.0.0.1 \
  --metrics.port 6060 \
  --cache=8192 \
  --maxpeers 250 \
  --rpc.txfeecap 0

[Install]
WantedBy=multi-user.target
EOF

# Lighthouse 服务（内部监听 5053）
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

ExecStart=/usr/local/bin/lighthouse beacon_node \
  --network sepolia \
  --datadir /data/lighthouse_sepolia \
  --execution-endpoint http://127.0.0.1:8551 \
  --execution-jwt /data/jwt/jwt.hex \
  --http \
  --http-address 127.0.0.1 \
  --http-port 5053 \
  --metrics \
  --metrics-address 127.0.0.1 \
  --metrics-port 5054 \
  --checkpoint-sync-url https://beaconstate-sepolia.chainsafe.io \
  --disable-upnp \
  --supernode

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable geth.service
sudo systemctl enable lighthouse-beacon.service
sudo systemctl restart geth.service
sudo systemctl restart lighthouse-beacon.service

##############################################
# 阶段 7：配置 Nginx 反向代理 Lighthouse RPC
##############################################
echo "⚙️ 配置 Nginx 反向代理 Lighthouse RPC..."
NGINX_CONF="/etc/nginx/sites-available/lighthouse_rpc.conf"
sudo tee $NGINX_CONF >/dev/null <<EOF
server {
    listen 0.0.0.0:5052;
    location / {
        proxy_pass http://127.0.0.1:5053;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_read_timeout 600s;        # 延长读取超时
        proxy_connect_timeout 180s;      # 延长连接超时

        proxy_buffering off;            # 关闭缓冲
        proxy_request_buffering off;    # 关闭请求缓冲
    }
}
EOF

sudo ln -sf $NGINX_CONF /etc/nginx/sites-enabled/lighthouse_rpc.conf
sudo nginx -t
sudo systemctl enable nginx
sudo systemctl restart nginx

echo "✅ Nginx 反向代理配置完成"

##############################################
# 阶段 8：配置防火墙
##############################################
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
# 阶段 9：完成信息
##############################################
echo "🎉 部署完成！节点已启动。"
echo "🧠 当前版本信息："
echo "   → Geth: $(geth version | grep -m1 'Version')"
echo "   → Lighthouse: $(lighthouse --version)"
echo "📊 查看日志："
echo "   sudo journalctl -fu geth.service"
echo "   sudo journalctl -fu lighthouse-beacon.service"
echo "🔍 查看同步状态："
echo "   curl -X POST --data '{\"jsonrpc\":\"2.0\",\"method\":\"eth_syncing\",\"params\":[],\"id\":1}' -H 'Content-Type: application/json' localhost:8545"
echo "   curl http://127.0.0.1:5052/eth/v1/node/syncing"
echo "✅ 如果 Geth 和 Lighthouse 都返回 false，则节点同步完成。"
