# Cloudflare WARP WireGuard 配置指南

本指南只用于 XHTTP 链路的 Gemini 专用 WARP 出站。启用后，easy_all 会在 Xray 内部新增
WireGuard 出站，并且只把 Gemini/AI Studio 会话所需的精确域名集合导向 WARP，包括 Gemini
本体、Google 登录、Google 首页、Gemini 静态资源、Gemini/AI Studio API 端点和相关 clients
端点；不会修改 VPS 系统默认路由，也不会把全量 `google.com`、全量 `googleapis.com` 或通用
`gstatic.com` 切到 WARP。
Mihomo 常用的 `www.gstatic.com/generate_204` 测速地址也不在 WARP 域名集合中。
Cloudflare WARP 普通 WireGuard endpoint 使用 Anycast，不能在 Xray 配置里可靠指定美西或其他
固定出口地区；如需稳定美西出口，应使用美西 VPS/代理作为单独出站。

## 方式一：脚本自动注册

执行：

```bash
sudo easy_all update-sub
```

在 `Gemini 相关域名是否经 Cloudflare WARP 出站？` 菜单选择：

```text
2. 自动注册免费 WARP 配置
```

脚本会优先使用系统里已有的 `wgcf`。如果没有，会从 `ViRb3/wgcf` 最新 release 下载当前系统架构
对应的 Linux 二进制，自动执行：

```bash
wgcf register
wgcf generate
```

生成的 `wgcf-account.toml` 和 `wgcf-profile.conf` 会保存在 `/etc/easy_all/xhttp-warp/`，
最终写入 `/etc/easy_all/state.env` 的字段包括：

```text
XHTTP_GEMINI_WARP_MODE=auto
XHTTP_WARP_PRIVATE_KEY=...
XHTTP_WARP_PEER_PUBLIC_KEY=...
XHTTP_WARP_ENDPOINT=...
XHTTP_WARP_ADDRESS=...
XHTTP_WARP_RESERVED=...
```

如果 Cloudflare WARP 注册接口返回 rate limit，换一个网络或稍后重试；也可以改用手动方式。

## 诊断 WARP 出口

如果 Gemini 超时或仍提示地区不可用，可以在 VPS 上临时启动一个仅监听本机的 SOCKS 入口，确认
Xray 内置 WARP 出站是否可用：

```bash
sudo jq '{
  log:{loglevel:"warning"},
  inbounds:[{tag:"diag-socks",listen:"127.0.0.1",port:18080,protocol:"socks",settings:{auth:"noauth",udp:false}}],
  outbounds:.outbounds,
  routing:{domainStrategy:"IPOnDemand",rules:[{type:"field",network:"tcp",outboundTag:"warp"}]}
}' /etc/easy_all/xray/config.json | sudo tee /tmp/easy_all-warp-diag.json >/dev/null

sudo /etc/easy_all/xray/xray run -config /tmp/easy_all-warp-diag.json >/tmp/easy_all-warp-diag.log 2>&1 &
pid=$!
sleep 1
curl -sS --max-time 20 --socks5-hostname 127.0.0.1:18080 https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|loc|colo|warp)='
kill "$pid"
```

正常结果应包含 `warp=on`。如果这里超时或 broken pipe，说明 WARP WireGuard 出站本身不可用，
通常需要更换 WARP 配置或改用手动配置。

## 方式二：手动获取已有配置

手动方式适合已经有 WARP / WARP+ 账号配置，或希望在本机以外的设备完成注册后再复制到 VPS。

1. 下载 `wgcf`

   到 `https://github.com/ViRb3/wgcf/releases` 下载当前系统对应的二进制。例如 Linux AMD64：

   ```bash
   WGCF_VERSION=2.2.32
   curl -fL -o wgcf \
     "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_amd64"
   chmod +x wgcf
   ```

   如果使用 macOS，也可以：

   ```bash
   brew install wgcf
   ```

2. 注册并生成 WireGuard 配置

   ```bash
   ./wgcf register
   ./wgcf generate
   ```

   生成结果是当前目录下的 `wgcf-profile.conf`。

3. 从 `wgcf-profile.conf` 读取字段

   ```ini
   [Interface]
   PrivateKey = ...
   Address = 172.16.0.2/32, 2606:4700:110:xxxx:xxxx:xxxx:xxxx:xxxx/128

   [Peer]
   PublicKey = ...
   Endpoint = engage.cloudflareclient.com:2408
   ```

   字段对应关系：

   | wgcf 字段 | easy_all 输入 |
   | --- | --- |
   | `PrivateKey` | `WARP WireGuard PrivateKey` |
   | `PublicKey` | `WARP Peer PublicKey` |
   | `Endpoint` | `WARP Endpoint` |
   | `Address` | `WARP Address 列表` |
   | `Reserved` | `WARP reserved 三字节` |

   `Reserved` 通常没有出现在 `wgcf-profile.conf` 中，直接使用默认 `0,0,0` 即可。

4. 在 easy_all 中启用手动配置

   ```bash
   sudo easy_all update-sub
   ```

   在菜单中选择：

   ```text
   3. 手动填写已有 WARP WireGuard 配置
   ```

   按提示填入上面的字段。只有 `PrivateKey` 必填；其它字段可以直接回车使用默认值，或按
   `wgcf-profile.conf` 显式填写。
