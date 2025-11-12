## 一键部署geth+lighthouse
wget -O eth_sep.sh https://raw.githubusercontent.com/erdongxin/eth_sep_rpc/refs/heads/main/eth_sep.sh && chmod +x eth_sep.sh && ./eth_sep.sh

## 内核优化 TCP 并发参数，并使用Nginx 做请求复用 + 缓冲，减轻 Lighthouse 高并发压力
wget -O optimize_lighthouse_rpc.sh https://raw.githubusercontent.com/erdongxin/eth_sep_rpc/refs/heads/main/optimize_lighthouse_rpc.sh && chmod +x optimize_lighthouse_rpc.sh && ./optimize_lighthouse_rpc.sh
