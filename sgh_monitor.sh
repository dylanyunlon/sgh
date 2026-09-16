#!/usr/bin/env bash
# ============================================================
#  深圳工会 商品库存监控脚本
#
#  监控所有活动专区的售罄商品, 有人退单(库存恢复)时报警
#  同时发现新活动/新商品也会提示
#
#  用法: bash sgh_monitor.sh              # 单次运行
#        bash sgh_monitor.sh --loop 60    # 每60秒轮询
#
#  Token 有效期至 2026-10-16
# ============================================================

set -euo pipefail

# ==================== 配置区 ====================
TOKEN="17c3688825a4f0385fdf5726ccd7a309"
COOKIE="JSESSIONID=MGNmNmMxZjgtYjk2MC00MjlhLTg3ZGYtYzgzMmRkMjBmYjlj;csrf_token=qypt"
CSRF="957d6cbaead54f3e8bde8ef4dbf2a7c5"
DEPT_ID="46"

SHOP_BASE="https://miniapp-gig.szzgh.org/benefits/web-plat"
UA="Mozilla/5.0 (iPhone; CPU iPhone OS 16_0_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.76(0x18004c3a) NetType/WIFI Language/zh_CN"
REFERER="https://servicewechat.com/wx184c95bb87569866/52/page-frame.html"

# 你关注的售罄商品ID (留空=监控所有售罄商品)
WATCH_IDS=()

# 状态文件 (记录上次库存, 检测变化)
STATE_FILE="/tmp/sgh_monitor_state.json"
# ==================== 配置区结束 ====================

ts_now() { python3 -c "import time; print(int(time.time()*1000))"; }

# Sign 用固定值试探, 如果被拦截再研究算法
shop_get() {
    local url="$1"
    local ts=$(ts_now)
    curl -s -k -X GET "$url" \
        -H "Host: miniapp-gig.szzgh.org" \
        -H "Connection: keep-alive" \
        -H "Timestamp: ${ts}" \
        -H "cookie: ${COOKIE}" \
        -H "content-type: application/json" \
        -H "csrf-token: ${CSRF}" \
        -H "Sign: 0000000000000000000000000000000000000000000000000000000000000000" \
        -H "token: ${TOKEN}" \
        -H "x-requested-with: XMLHttpRequest" \
        -H "Accept-Encoding: gzip,compress,br,deflate" \
        -H "User-Agent: ${UA}" \
        -H "Referer: ${REFERER}" \
        --compressed
}

shop_post() {
    local url="$1" data="$2"
    local ts=$(ts_now)
    curl -s -k -X POST "$url" \
        -H "Host: miniapp-gig.szzgh.org" \
        -H "Connection: keep-alive" \
        -H "Timestamp: ${ts}" \
        -H "cookie: ${COOKIE}" \
        -H "content-type: application/json" \
        -H "csrf-token: ${CSRF}" \
        -H "Sign: 0000000000000000000000000000000000000000000000000000000000000000" \
        -H "token: ${TOKEN}" \
        -H "x-requested-with: XMLHttpRequest" \
        -H "Accept-Encoding: gzip,compress,br,deflate" \
        -H "User-Agent: ${UA}" \
        -H "Referer: ${REFERER}" \
        --compressed \
        -d "$data"
}

do_monitor() {
    echo "🔍 $(date '+%Y-%m-%d %H:%M:%S') 开始扫描..."
    echo ""

    # 1. 获取当前活动专区信息
    local zone_resp
    zone_resp=$(shop_get "${SHOP_BASE}/zone/zoneInfo?deptId=${DEPT_ID}&id=1549067771143876608")

    if echo "$zone_resp" | grep -qi 'error\|forbidden\|401\|403'; then
        echo "❌ 活动信息获取失败 (可能需要更新 Sign/Token)"
        echo "   resp: ${zone_resp:0:200}"
        return 1
    fi

    local zone_name zone_end
    zone_name=$(echo "$zone_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('zoneInfo',{}).get('zoneName','未知活动'))" 2>/dev/null || echo "未知")
    zone_end=$(echo "$zone_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('zoneInfo',{}).get('endTime',''))" 2>/dev/null || echo "")
    echo "📦 活动: ${zone_name} (截止: ${zone_end})"
    echo ""

    # 2. 获取所有主题
    local themes_resp
    themes_resp=$(shop_post "${SHOP_BASE}/zone/themeList" \
        "{\"zoneId\":\"1549067771143876608\",\"deptId\":\"${DEPT_ID}\"}")

    local theme_ids
    theme_ids=$(echo "$themes_resp" | python3 -c "
import sys,json
try:
    for t in json.load(sys.stdin).get('themeGoodsList',[]):
        print(t.get('id','')+'|'+t.get('themeName',''))
except: pass
" 2>/dev/null || true)

    # 3. 遍历每个主题, 翻页拉取所有商品
    local all_items_json="[]"

    while IFS='|' read -r tid tname; do
        [ -z "$tid" ] && continue
        local page=1
        while true; do
            local resp
            resp=$(shop_post "${SHOP_BASE}/zone/themeGoodsPageList" \
                "{\"page\":${page},\"limit\":20,\"zoneId\":\"1549067771143876608\",\"themeId\":\"${tid}\",\"goodsClassifyId\":\"\",\"deptId\":\"${DEPT_ID}\"}")

            local items has_next
            items=$(echo "$resp" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for item in d.get('page',{}).get('list',[]):
        print(json.dumps({
            'id': item.get('id',''),
            'name': item.get('goodsName',''),
            'price': item.get('priceStr', str(item.get('priceMin',''))),
            'stock': item.get('snappedStock',0),
            'total': item.get('num',0),
            'theme': '${tname}'
        }, ensure_ascii=False))
except: pass
" 2>/dev/null || true)

            has_next=$(echo "$resp" | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('page',{}).get('hasNextPage',False))
except: print('False')
" 2>/dev/null || echo "False")

            while IFS= read -r line; do
                [ -z "$line" ] && continue
                all_items_json=$(echo "$all_items_json" | python3 -c "
import sys,json
arr=json.load(sys.stdin)
arr.append(json.loads('$line'))
print(json.dumps(arr, ensure_ascii=False))
" 2>/dev/null)
            done <<< "$items"

            [ "$has_next" = "True" ] && page=$((page+1)) || break
        done
    done <<< "$theme_ids"

    # 4. 对比上次状态, 检测变化
    python3 -c "
import json, os, sys
from datetime import datetime

items = json.loads('''${all_items_json}''')
state_file = '${STATE_FILE}'

# Load previous state
prev = {}
if os.path.exists(state_file):
    with open(state_file) as f:
        prev = json.load(f)

# Current state
curr = {}
soldout = []
available = []
restocked = []
new_items = []

for item in items:
    iid = item['id']
    curr[iid] = item
    stock = item['stock']
    total = item['total']
    name = item['name']
    price = item['price']
    theme = item['theme']

    if stock == 0:
        soldout.append(item)
    else:
        available.append(item)

    # Detect changes
    if iid in prev:
        old_stock = prev[iid]['stock']
        if old_stock == 0 and stock > 0:
            restocked.append(item)
    else:
        if prev:  # only flag new if we had previous state
            new_items.append(item)

# Print report
print(f'📊 商品总数: {len(items)}  售罄: {len(soldout)}  有货: {len(available)}')
print()

if restocked:
    print('🚨🚨🚨 库存恢复 (有人退单!) 🚨🚨🚨')
    for item in restocked:
        print(f'  🔥 {item[\"name\"][:35]}  ¥{item[\"price\"]}  库存: 0→{item[\"stock\"]}')
    print()

if new_items:
    print('🆕 新上架商品:')
    for item in new_items:
        icon = '🟢' if item['stock'] > 0 else '🔴'
        print(f'  {icon} {item[\"name\"][:35]}  ¥{item[\"price\"]}  库存:{item[\"stock\"]}/{item[\"total\"]}')
    print()

print('🔴 售罄商品:')
for item in sorted(soldout, key=lambda x: float(x['price']) if x['price'] else 0):
    print(f'  {item[\"name\"][:40]:42s} ¥{item[\"price\"]:>9s}  [{item[\"theme\"]}]')

print()
print('🟢 有货商品:')
for item in sorted(available, key=lambda x: x['stock']):
    pct = round(item['stock']/item['total']*100) if item['total'] else 0
    bar = '█' * (pct//10) + '░' * (10 - pct//10)
    print(f'  {item[\"name\"][:35]:37s} ¥{item[\"price\"]:>9s}  {bar} {item[\"stock\"]}/{item[\"total\"]}')

# Save current state
with open(state_file, 'w') as f:
    json.dump(curr, f, ensure_ascii=False)
"
    echo ""
}

# ======== 主入口 ========

if [ "${1:-}" = "--loop" ]; then
    interval="${2:-60}"
    echo "================================================"
    echo "  深圳工会 · 商品库存监控 (每${interval}秒)"
    echo "  Ctrl+C 停止"
    echo "================================================"
    while true; do
        do_monitor
        echo "⏳ ${interval}秒后下次扫描..."
        echo ""
        sleep "$interval"
    done
else
    echo "================================================"
    echo "  深圳工会 · 商品库存监控 (单次)"
    echo "================================================"
    echo ""
    do_monitor
    echo "======== 完成 $(date '+%H:%M:%S') ========"
fi
