#!/usr/bin/env bash
# ============================================================
#  深圳工会 积分自动化脚本
#  分享文章 3篇=30分 + 观看视频 3个=30分 + 收听音频 3次=60分
#  每日最高 120 积分
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

API_SHARE="TC31b82aK2JrcDmeWT0z+A=="        # 分享文章 type=106
API_VIDEO="7gTfsPqxqg3y1Eb9ISNLOA=="        # 观看视频 type=105
API_AUDIO="3ShqOken1Rtz3P0Tqjjrvw=="        # 收听音频 type=108

COL_VIDEO="D8C9821B50C54E7FA052AAA21EBBB301"
COL_AUDIO="73EAC971970C40BA940380DEDA8971A1"
MAX_PAGES=5
SKIP_THRESHOLD=5
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

fetch_page() {
    local column="$1" page="$2"
    post_json "${BASE}/ebs/operationNewsInfo/queryShowPageList" \
        "{\"titles\":\"\",\"pkOperationColumn\":\"${column}\",\"page\":${page},\"limit\":10}" | python3 -c "
import sys,json
try:
    for r in json.load(sys.stdin).get('data',{}).get('list',[]):
        print(r.get('pkOperationNewsInfo','')+'|'+r.get('titles',''))
except: pass
" 2>/dev/null || true
}

run_task() {
    local label="$1" column="$2" btype="$3" apiid="$4" target="$5" pts="$6"
    local success=0 page=1 consec_skip=0 done=0

    while [ $success -lt $target ] && [ $page -le $MAX_PAGES ] && [ $done -eq 0 ]; do
        local items
        items=$(fetch_page "$column" "$page")
        [ -z "$items" ] && { page=$((page+1)); continue; }

        while IFS='|' read -r pk title; do
            [ $success -ge $target ] && break
            [ $done -eq 1 ] && break
            [ -z "$pk" ] && continue

            resp=$(post_json "${BASE}/point/pointTask/completePointTask" \
                "{\"apiId\":\"${apiid}\",\"buryingPointType\":${btype},\"systemType\":0,\"pkRelevance\":\"${pk}\"}")
            c=$(echo "$resp"|jval code)
            m=$(echo "$resp"|jval msg)
            d=$(echo "$resp"|jval data)

            case "$c" in
                0)  echo "  ✅ ${title:0:40}: ${d}"
                    success=$((success+1)); consec_skip=0 ;;
                202|203)
                    consec_skip=$((consec_skip+1))
                    if [ $consec_skip -ge $SKIP_THRESHOLD ]; then
                        echo "  🏁 连续 ${consec_skip} 条已完成, 今日${label}已满"
                        done=1
                    fi ;;
                *)  echo "  ❌ ${title:0:40}: code=${c} ${m}" ;;
            esac
            sleep 1
        done <<< "$items"
        page=$((page+1))
    done
    echo "  📝 今日${label}: +${success} 次 (+$((success*pts))积分)"
}

# ======== 主流程 ========

echo "================================================"
echo "  深圳工会 · 每日积分任务"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================"
echo ""

echo "🔑 检查登录..."
RESP=$(post_empty "${BASE}/point/memberPoint/getUserPoint")
if echo "$RESP" | grep -qi 'forbidden\|<html'; then
    echo "❌ 403 被拦截"; exit 1
fi
CODE=$(echo "$RESP" | jval code)
if [ "$CODE" != "0" ]; then
    echo "❌ 失败: $RESP"; exit 1
fi
BEFORE=$(echo "$RESP" | jval data)
echo "✅ 当前积分: ${BEFORE}"
echo ""

echo "📤 分享文章 (每篇10积分, 上限3篇=30)..."
run_task "分享" "" 106 "$API_SHARE" 3 10
echo ""

echo "🎥 观看视频 (每个10积分, 上限3个=30)..."
run_task "观看" "$COL_VIDEO" 105 "$API_VIDEO" 3 10
echo ""

echo "🎧 收听音频 (每次20积分, 上限3次=60)..."
run_task "收听" "$COL_AUDIO" 108 "$API_AUDIO" 3 20
echo ""

RESP=$(post_empty "${BASE}/point/memberPoint/getUserPoint")
AFTER=$(echo "$RESP" | jval data)
GAINED=$((AFTER - BEFORE))
echo "📊 积分: ${BEFORE} → ${AFTER} (+${GAINED})"
echo ""
echo "======== 完成 $(date '+%H:%M:%S') ========"