#!/bin/bash
# sync-secrets.sh — 同步 nginx secure_link_secret 和 docservice storage.fs.secretString
#
# 问题：容器 entrypoint (run-document-server.sh) 生成随机 secret 写入 local.json 和 nginx，
#       但我们替换了 default.json（源码版本），导致 secretString 可能不一致。
#       nginx 用 secure_link 验证 Editor.bin 下载 URL，secret 不匹配 → 403 → "Download failed"
#
# 方案：从 local.json 读取 secretString，写入 nginx ds.conf 的 secure_link_secret
#       如果 local.json 没有，则从 nginx 读取并写入 local.json
#
# 调用时机：容器 entrypoint 之后、supervisor 启动服务之前

set -e

NGINX_CONF="/etc/nginx/conf.d/ds.conf"
LOCAL_CONF="/etc/onlyoffice/documentserver/local.json"

echo "[sync-secrets] Syncing nginx secure_link_secret with docservice storage secret..."

# 尝试从 local.json 读取 storage.fs.secretString
if command -v json &>/dev/null; then
    JSON_TOOL="json"
elif command -v node &>/dev/null; then
    JSON_TOOL="node"
else
    echo "[sync-secrets] WARNING: no json/node tool available, skipping sync"
    exit 0
fi

# 读取 local.json 中的 secretString
if [ "$JSON_TOOL" = "json" ]; then
    SECRET=$(json -f "$LOCAL_CONF" storage.fs.secretString 2>/dev/null || echo "")
else
    SECRET=$(node -e "
        try {
            var c = require('$LOCAL_CONF');
            console.log((c.storage && c.storage.fs && c.storage.fs.secretString) || '');
        } catch(e) { console.log(''); }
    " 2>/dev/null || echo "")
fi

if [ -z "$SECRET" ]; then
    # local.json 没有 secretString，从 nginx 读取
    SECRET=$(grep -oP 'set \$secure_link_secret \K[^;]+' "$NGINX_CONF" 2>/dev/null || echo "")
    if [ -z "$SECRET" ]; then
        echo "[sync-secrets] WARNING: no secret found in either config, generating one"
        SECRET=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 20)
    fi
    # 写入 local.json
    if [ "$JSON_TOOL" = "node" ]; then
        node -e "
            var fs = require('fs');
            var conf = JSON.parse(fs.readFileSync('$LOCAL_CONF', 'utf8'));
            if (!conf.storage) conf.storage = {};
            if (!conf.storage.fs) conf.storage.fs = {};
            conf.storage.fs.secretString = '$SECRET';
            fs.writeFileSync('$LOCAL_CONF', JSON.stringify(conf, null, 2));
        "
        chown ds:ds "$LOCAL_CONF" 2>/dev/null || true
    fi
fi

# 写入 nginx ds.conf
if grep -q 'secure_link_secret' "$NGINX_CONF"; then
    sed -i "s|set \$secure_link_secret.*|set \$secure_link_secret ${SECRET};|" "$NGINX_CONF"
    echo "[sync-secrets] Updated nginx secure_link_secret"
else
    echo "[sync-secrets] WARNING: secure_link_secret not found in nginx config"
fi

echo "[sync-secrets] Secret synced: ${SECRET:0:4}...${SECRET: -4}"
