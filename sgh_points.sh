#!/usr/bin/env bash
# ============================================================
#  深圳工会 积分自动化脚本
#  观看视频(3个30分) + 分享文章(3篇30分) = 每日最高60积分
#
#  用法: chmod +x sgh_points.sh && ./sgh_points.sh
#  Token 有效期至 2026-10-16
# ============================================================

set -euo pipefail

# ==================== 配置区 ====================
TOKEN="17c3688825a4f0385fdf5726ccd7a309"
MOBILE="UeAKQ8JUV1mvCv7O475miw=="
BASE="https://lsapp.szzgh.org:99/api/ebs"
UA="Mozilla/5.0 (iPhone; CPU iPhone OS 16_0_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.76(0x18004c3a) NetType/WIFI Language/zh_CN"
REFERER="https://servicewechat.com/wxb7a23c5650537af6/412/page-frame.html"

API_SHARE="TC31b82aK2JrcDmeWT0z+A=="
API_VIDEO="7gTfsPqxqg3y1Eb9ISNLOA=="
COL_VIDEO="D8C9821B50C54E7FA052AAA21EBBB301"
# ==================== 配置区结束 ====================

post_json() {
    curl -s -k -X POST "$1" \
        -H "Host: lsapp.szzgh.org:99" \
        -H "Connection: keep-alive" \
        -H "token: ${TOKEN}" \
        -H "mobile: ${MOBILE}" \
        -H "content-type: application/json" \
        -H "Accept-Encoding: gzip,compress,br,deflate" \
        -H "User-Agent: ${UA}" \
        -H "Referer: ${REFERER}" \
        --compressed \
        -d "$2"
}

post_empty() {
    curl -s -k -X POST "$1" \
        -H "Host: lsapp.szzgh.org:99" \
        -H "Connection: keep-alive" \
        -H "Content-Length: 0" \
        -H "token: ${TOKEN}" \
        -H "content-type: application/x-www-form-urlencoded" \
        -H "mobile: ${MOBILE}" \
        -H "Accept-Encoding: gzip,compress,br,deflate" \
        -H "User-Agent: ${UA}" \
        -H "Referer: ${REFERER}" \
        --compressed
}

jval() {
    python3 -c "
import sys,json
try:
    v=json.load(sys.stdin)
    for k in '$1'.split('.'):
        if isinstance(v,dict): v=v.get(k,'')
        else: v=''
    print('' if v is None else v)
except: print('')"
}

echo "================================================"
echo "  深圳工会 · 每日积分任务"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================"
echo ""

# 1. 检查登录
echo "🔑 检查登录..."
RESP=$(post_empty "${BASE}/point/memberPoint/getUserPoint")
if echo "$RESP" | grep -qi 'forbidden\|<html'; then
    echo "❌ 403 被拦截: $RESP"; exit 1
fi
CODE=$(echo "$RESP" | jval code)
if [ "$CODE" != "0" ]; then
    echo "❌ 失败: $RESP"; exit 1
fi
echo "✅ 当前积分: $(echo "$RESP" | jval data)"
echo ""

# 2. 拉取文章列表 (通用, 包含所有栏目, infoType=0 是文章)
echo "📋 拉取文章列表..."
ART_IDS=$(post_json "${BASE}/ebs/operationNewsInfo/queryShowPageList" \
    '{"titles":"","pkOperationColumn":"","page":1,"limit":10}' | python3 -c "
import sys,json
try:
    for r in json.load(sys.stdin).get('data',{}).get('list',[]):
        print(r.get('pkOperationNewsInfo','')+'|'+r.get('titles',''))
except: pass
" 2>/dev/null || true)
AC=$(echo "$ART_IDS" | grep -c '|' 2>/dev/null || echo 0)
echo "  文章: ${AC} 条"

# 3. 拉取视频列表 (infoType=2)
echo "📋 拉取视频列表..."
VID_IDS=$(post_json "${BASE}/ebs/operationNewsInfo/queryShowPageList" \
    "{\"titles\":\"\",\"pkOperationColumn\":\"${COL_VIDEO}\",\"page\":1,\"limit\":10}" | python3 -c "
import sys,json
try:
    for r in json.load(sys.stdin).get('data',{}).get('list',[]):
        print(r.get('pkOperationNewsInfo','')+'|'+r.get('titles',''))
except: pass
" 2>/dev/null || true)
VC=$(echo "$VID_IDS" | grep -c '|' 2>/dev/null || echo 0)
echo "  视频: ${VC} 条"
echo ""

# 4. 分享文章 (每篇10积分, 上限3篇=30积分)
echo "📤 分享文章 (每篇10积分, 上限3篇)..."
n=0
if [ -n "$ART_IDS" ]; then
    while IFS='|' read -r pk title; do
        [ $n -ge 3 ] && break
        [ -z "$pk" ] && continue
        resp=$(post_json "${BASE}/point/pointTask/completePointTask" \
            "{\"apiId\":\"${API_SHARE}\",\"buryingPointType\":106,\"systemType\":0,\"pkRelevance\":\"${pk}\"}")
        c=$(echo "$resp"|jval code); m=$(echo "$resp"|jval msg); d=$(echo "$resp"|jval data)
        if [ "$c" = "0" ]; then echo "  ✅ ${title:0:35}: ${d}"
        elif [ "$c" = "202" ]; then echo "  ⏭️  ${title:0:35}: ${m}"
        else echo "  ❌ ${title:0:35}: code=${c} ${m}"
        fi
        n=$((n+1)); sleep 2
    done <<< "$ART_IDS"
else
    echo "  ⚠️  列表空"
fi
echo ""

# 5. 观看视频 (每个10积分, 上限3个=30积分)
echo "🎥 观看视频 (每个10积分, 上限3个)..."
n=0
if [ -n "$VID_IDS" ]; then
    while IFS='|' read -r pk title; do
        [ $n -ge 3 ] && break
        [ -z "$pk" ] && continue
        resp=$(post_json "${BASE}/point/pointTask/completePointTask" \
            "{\"apiId\":\"${API_VIDEO}\",\"buryingPointType\":105,\"systemType\":0,\"pkRelevance\":\"${pk}\"}")
        c=$(echo "$resp"|jval code); m=$(echo "$resp"|jval msg); d=$(echo "$resp"|jval data)
        if [ "$c" = "0" ]; then echo "  ✅ ${title:0:35}: ${d}"
        elif [ "$c" = "202" ]; then echo "  ⏭️  ${title:0:35}: ${m}"
        else echo "  ❌ ${title:0:35}: code=${c} ${m}"
        fi
        n=$((n+1)); sleep 2
    done <<< "$VID_IDS"
else
    echo "  ⚠️  列表空"
fi
echo ""

# 6. 最终积分
RESP=$(post_empty "${BASE}/point/memberPoint/getUserPoint")
echo "📊 最终积分: $(echo "$RESP" | jval data)"
echo ""
echo "======== 完成 $(date '+%H:%M:%S') ========"
