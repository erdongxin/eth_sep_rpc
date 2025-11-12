#!/bin/bash
set -e

echo "🚀 开始单机 Lighthouse RPC 最大化承载优化..."

##############################################
# 阶段 1：TCP 内核调优
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
echo "✅ TCP 内核调优完成"

##############################################
# 阶段 2：安装 Nginx
##############################################
echo "📦 安装 Nginx..."
sudo apt update -y
sudo apt install -y nginx
sudo systemctl enable nginx
sudo systemctl start nginx

##############################################
# 阶段 3：配置 Nginx 反向代理
##############################################
echo "⚙️ 配置 Nginx 反向代理 Lighthouse RPC..."

NGINX_CONF="/etc/nginx/sites-available/lighthouse_rpc.conf"
sudo tee $NGINX_CONF >/dev/null <<EOF
server {
    listen 5052;

    location / {
        proxy_pass http://127.0.0.1:5052;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_read_timeout 60s;
        proxy_connect_timeout 10s;

        # 缓冲和队列优化
        proxy_buffering on;
        proxy_buffers 16 64k;
        proxy_busy_buffers_size 128k;
        proxy_max_temp_file_size 256k;
    }
}
EOF

sudo ln -sf $NGINX_CONF /etc/nginx/sites-enabled/lighthouse_rpc.conf
sudo nginx -t
sudo systemctl restart nginx
echo "✅ Nginx 反向代理配置完成"

##############################################
# 阶段 4：提醒 Lighthouse 配置
##############################################
echo ""
echo "🧠 确保你的 Lighthouse beacon node HTTP 仍监听本机:"
echo "   --http --http-address 127.0.0.1 --http-port 5052"
echo ""
echo "🎯 外部节点现在通过 Nginx 访问 RPC:"
echo "   http://<你的机器IP>:5052"

echo ""
echo "🎉 优化完成！单机 Lighthouse RPC 承载能力已最大化。"
echo "💡 建议监控连接数和 CPU 使用率："
echo "   sudo netstat -an | grep ESTABLISHED | wc -l"
echo "   htop"
