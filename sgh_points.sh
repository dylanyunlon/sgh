#!/usr/bin/env bash
# ============================================================
#  深圳工会 积分自动化脚本 (完整版)
#
#  ① 每日签到        type=101
#  ② 阅读文章 3篇    type=104  10x3=30
#  ③ 分享文章 3篇    type=106  10x3=30
#  ④ 观看视频 3个    type=105  10x3=30
#  ⑤ 收听音频 3次    type=108  20x3=60
#  ⑥ 了解工会 8项    type=108  10x8=80
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

API_LOGIN="snlZgkXAFnuxIoLsfZQj7w=="       # 每日签到  101
API_READ="OQAEvjcv2rK5bLUV7pdsCQ=="         # 阅读文章  104
API_SHARE="TC31b82aK2JrcDmeWT0z+A=="        # 分享文章  106
API_VIDEO="7gTfsPqxqg3y1Eb9ISNLOA=="        # 观看视频  105
API_AUDIO="3ShqOken1Rtz3P0Tqjjrvw=="        # 收听音频  108

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

# 单次无参任务
do_once() {
    local label="$1" btype="$2" apiid="$3"
    local resp c m d
    resp=$(post_json "${BASE}/point/pointTask/completePointTask" \
        "{\"apiId\":\"${apiid}\",\"buryingPointType\":${btype},\"systemType\":0}")
    c=$(echo "$resp"|jval code); m=$(echo "$resp"|jval msg); d=$(echo "$resp"|jval data)
    case "$c" in
        0)   echo "  ✅ ${label}: ${d}" ;;
        202) echo "  ⏭️  ${label}: 已完成" ;;
        *)   echo "  ❌ ${label}: code=${c} ${m}" ;;
    esac
}

# 翻页任务
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
            c=$(echo "$resp"|jval code); m=$(echo "$resp"|jval msg); d=$(echo "$resp"|jval data)

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
    echo "  📝 今日${label}: +${success} (+$((success*pts))积分)"
}

# ======== 主流程 ========

echo "================================================"
echo "  深圳工会 · 每日积分任务 (完整版)"
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

# ① 每日签到
echo "📅 每日签到..."
do_once "每日签到" 101 "$API_LOGIN"
echo ""

# ② 阅读文章
echo "📖 阅读文章 (10积分x3)..."
run_task "阅读" "" 104 "$API_READ" 3 10
echo ""

# ③ 分享文章
echo "📤 分享文章 (10积分x3)..."
run_task "分享" "" 106 "$API_SHARE" 3 10
echo ""

# ④ 观看视频
echo "🎥 观看视频 (10积分x3)..."
run_task "观看" "$COL_VIDEO" 105 "$API_VIDEO" 3 10
echo ""

# ⑤ 收听音频
echo "🎧 收听音频 (20积分x3)..."
run_task "收听" "$COL_AUDIO" 108 "$API_AUDIO" 3 20
echo ""

# ⑥ 了解工会 (8个页面任务, 每个10积分, 无需pkRelevance)
echo "🏛️  了解工会 (10积分x8)..."
UNION_TASKS=(
    "gweOTYecD0B676wVP0lcIw==|深工学堂"
    "89U+lcXtCR4vPC/TnJOMWw==|工匠云课堂"
    "1JBT8bMY71gB8J9PhpMBcA==|疗休养基地"
    "jpHK5AIuPWQabBbHFGWx4A==|困难帮扶"
    "/tQerZGZB3v6zd/n2uY6Hw==|深工守护"
    "/YDJTfWqIzGvtapXOqX3+w==|法律法规"
    "IWxueuk34ir6yZbhR2h+JQ==|技能竞赛"
    "cZJeNDa8MiBgi21JccALAQ==|互助保障"
)
union_success=0
for entry in "${UNION_TASKS[@]}"; do
    IFS='|' read -r apiid name <<< "$entry"
    resp=$(post_json "${BASE}/point/pointTask/completePointTask" \
        "{\"systemType\":0,\"buryingPointType\":108,\"apiId\":\"${apiid}\"}")
    c=$(echo "$resp"|jval code); m=$(echo "$resp"|jval msg); d=$(echo "$resp"|jval data)
    case "$c" in
        0)   echo "  ✅ ${name}: ${d}"; union_success=$((union_success+1)) ;;
        202) echo "  ⏭️  ${name}: 已完成" ;;
        *)   echo "  ❌ ${name}: code=${c} ${m}" ;;
    esac
    sleep 1
done
echo "  📝 今日了解工会: +${union_success} (+$((union_success*10))积分)"
echo ""

# 最终积分
RESP=$(post_empty "${BASE}/point/memberPoint/getUserPoint")
AFTER=$(echo "$RESP" | jval data)
GAINED=$((AFTER - BEFORE))
echo "📊 积分: ${BEFORE} → ${AFTER} (+${GAINED})"
echo ""
echo "======== 完成 $(date '+%H:%M:%S') ========"