#!/usr/bin/env bash
# ============================================================
#  深圳工会 商品库存监控脚本
#
#  单次运行: 显示所有商品库存
#  循环运行: 盯"送团圆"和"送伴侣"售罄商品, 退单立刻报警+发邮件
#
#  轮询策略:
#    常规: 30s ±5s 随机
#    高峰(20:00-22:00): 15s ±3s 随机
#    检测到退单: 加速5s轮询持续3分钟
#
#  用法: bash sgh_monitor.sh              # 单次全量
#        bash sgh_monitor.sh --loop       # 持续监控
# ============================================================

set -euo pipefail

# ==================== 商城配置 ====================
TOKEN="17c3688825a4f0385fdf5726ccd7a309"
COOKIE="JSESSIONID=MGNmNmMxZjgtYjk2MC00MjlhLTg3ZGYtYzgzMmRkMjBmYjlj;csrf_token=qypt"
CSRF="957d6cbaead54f3e8bde8ef4dbf2a7c5"
DEPT_ID="46"
ZONE_ID="1549067771143876608"

SHOP_BASE="https://miniapp-gig.szzgh.org/benefits/web-plat"
UA="Mozilla/5.0 (iPhone; CPU iPhone OS 16_0_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.76(0x18004c3a) NetType/WIFI Language/zh_CN"
REFERER="https://servicewechat.com/wx184c95bb87569866/52/page-frame.html"

# WATCH_THEMES=("送团圆" "送伴侣")
WATCH_THEMES=( "送伴侣")

# ==================== 邮件配置 ====================
SMTP_HOST="smtp.exmail.qq.com"
SMTP_PORT="465"
MAIL_FROM="20204890215@stu.usc.edu.cn"
MAIL_PASS="Us077264"
MAIL_TO="dogechat@163.com"

# ==================== 轮询配置 ====================
NORMAL_BASE=30
NORMAL_JITTER=5
PEAK_BASE=15
PEAK_JITTER=3
RUSH_INTERVAL=5
RUSH_DURATION=180
PEAK_START=20
PEAK_END=22

STATE_FILE="/tmp/sgh_monitor_state.json"
# ==================== 配置区结束 ====================

ts_now() { python3 -c "import time; print(int(time.time()*1000))"; }

shop_post() {
    curl -s -k -X POST "$1" \
        -H "Host: miniapp-gig.szzgh.org" \
        -H "Connection: keep-alive" \
        -H "Timestamp: $(ts_now)" \
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
        -d "$2"
}

shop_get() {
    curl -s -k -X GET "$1" \
        -H "Host: miniapp-gig.szzgh.org" \
        -H "Connection: keep-alive" \
        -H "Timestamp: $(ts_now)" \
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

# -------- 邮件通知 --------
send_mail() {
    local subject="$1"
    local body="$2"
    python3 -c "
import smtplib
from email.mime.text import MIMEText
from email.header import Header

msg = MIMEText('''$body''', 'plain', 'utf-8')
msg['From'] = '${MAIL_FROM}'
msg['To'] = '${MAIL_TO}'
msg['Subject'] = Header('$subject', 'utf-8')

try:
    s = smtplib.SMTP_SSL('${SMTP_HOST}', ${SMTP_PORT}, timeout=10)
    s.login('${MAIL_FROM}', '${MAIL_PASS}')
    s.sendmail('${MAIL_FROM}', '${MAIL_TO}', msg.as_string())
    s.quit()
    print('📧 邮件已发送')
except Exception as e:
    print(f'📧 邮件发送失败: {e}')
" 2>&1
}

# -------- 轮询间隔计算 --------
calc_interval() {
    local rush_until="${1:-0}"
    python3 -c "
import time, random
now = time.time()
rush_until = ${rush_until}
hour = int(time.strftime('%H'))

if now < rush_until:
    iv = ${RUSH_INTERVAL}; mode = 'RUSH'
elif ${PEAK_START} <= hour < ${PEAK_END}:
    iv = ${PEAK_BASE} + random.randint(-${PEAK_JITTER}, ${PEAK_JITTER}); mode = 'PEAK'
else:
    iv = ${NORMAL_BASE} + random.randint(-${NORMAL_JITTER}, ${NORMAL_JITTER}); mode = 'NORMAL'
print(f'{iv} {mode}')
"
}

# -------- 拉取所有商品 --------
fetch_all_items() {
    local themes_resp
    themes_resp=$(shop_post "${SHOP_BASE}/zone/themeList" \
        "{\"zoneId\":\"${ZONE_ID}\",\"deptId\":\"${DEPT_ID}\"}")

    echo "$themes_resp" | python3 -c "
import sys, json
try:
    for t in json.load(sys.stdin).get('themeGoodsList',[]):
        print(t.get('id','') + '|' + t.get('themeName',''))
except: pass
" 2>/dev/null | while IFS='|' read -r tid tname; do
        [ -z "$tid" ] && continue
        local page=1
        while true; do
            local resp
            resp=$(shop_post "${SHOP_BASE}/zone/themeGoodsPageList" \
                "{\"page\":${page},\"limit\":20,\"zoneId\":\"${ZONE_ID}\",\"themeId\":\"${tid}\",\"goodsClassifyId\":\"\",\"deptId\":\"${DEPT_ID}\"}")

            echo "$resp" | python3 -c "
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
            'theme': '$tname'
        }, ensure_ascii=False))
except: pass
" 2>/dev/null

            local has_next
            has_next=$(echo "$resp" | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('page',{}).get('hasNextPage',False))
except: print('False')
" 2>/dev/null || echo "False")
            [ "$has_next" = "True" ] && page=$((page+1)) || break
        done
    done
}

# -------- 完整报告 --------
report_full() {
    local items_jsonl="$1"
    echo "$items_jsonl" | python3 -c "
import sys, json, os

items = [json.loads(l) for l in sys.stdin if l.strip()]
sf = '${STATE_FILE}'
prev = {}
if os.path.exists(sf):
    with open(sf) as f: prev = json.load(f)

curr = {}; soldout = []; available = []; restocked = []; new_items = []
for item in items:
    iid = item['id']; curr[iid] = item
    (soldout if item['stock']==0 else available).append(item)
    if iid in prev:
        if prev[iid]['stock']==0 and item['stock']>0: restocked.append(item)
    elif prev: new_items.append(item)

print(f'📊 商品总数: {len(items)}  售罄: {len(soldout)}  有货: {len(available)}')
print()

if restocked:
    print('🚨🚨🚨 库存恢复 (有人退单!) 🚨🚨🚨')
    for i in restocked:
        print(f'  🔥 {i[\"name\"][:35]}  ¥{i[\"price\"]}  库存: 0→{i[\"stock\"]}')
    print()

if new_items:
    print('🆕 新上架商品:')
    for i in new_items:
        icon = '🟢' if i['stock']>0 else '🔴'
        print(f'  {icon} {i[\"name\"][:35]}  ¥{i[\"price\"]}  库存:{i[\"stock\"]}/{i[\"total\"]}')
    print()

print('🔴 售罄商品:')
for i in sorted(soldout, key=lambda x: float(x['price']) if x['price'] else 0):
    print(f'  {i[\"name\"][:40]:42s} ¥{i[\"price\"]:>9s}  [{i[\"theme\"]}]')
print()
print('🟢 有货商品:')
for i in sorted(available, key=lambda x: x['stock']):
    pct = round(i['stock']/i['total']*100) if i['total'] else 0
    bar = '█'*(pct//10) + '░'*(10-pct//10)
    print(f'  {i[\"name\"][:35]:37s} ¥{i[\"price\"]:>9s}  {bar} {i[\"stock\"]}/{i[\"total\"]}')

with open(sf,'w') as f: json.dump(curr, f, ensure_ascii=False)
print(f'__RESTOCKED__:{len(restocked)}')

# Output restock details for email
if restocked:
    lines = []
    for i in restocked:
        lines.append(f'{i[\"name\"]} ¥{i[\"price\"]} 库存:0→{i[\"stock\"]} [{i[\"theme\"]}]')
    print('__RESTOCK_DETAIL__:' + '|'.join(lines))
"
}

# -------- 精简报告 (循环模式) --------
report_watch() {
    local items_jsonl="$1"
    local watch_pattern
    watch_pattern=$(printf '%s|' "${WATCH_THEMES[@]}")
    watch_pattern="${watch_pattern%|}"

    echo "$items_jsonl" | python3 -c "
import sys, json, os, re
from datetime import datetime

items = [json.loads(l) for l in sys.stdin if l.strip()]
sf = '${STATE_FILE}'
watch_re = re.compile(r'${watch_pattern}')

prev = {}
if os.path.exists(sf):
    with open(sf) as f: prev = json.load(f)

curr = {}; restocked = []; new_items = []; watched_soldout = []
for item in items:
    iid = item['id']; curr[iid] = item
    if not watch_re.search(item['theme']): continue
    if item['stock']==0: watched_soldout.append(item)
    if iid in prev:
        if prev[iid]['stock']==0 and item['stock']>0: restocked.append(item)
    elif prev: new_items.append(item)

now = datetime.now().strftime('%H:%M:%S')

if restocked:
    print()
    print('🚨🚨🚨 库存恢复 (有人退单!) 🚨🚨🚨')
    for i in restocked:
        old = prev.get(i['id'],{}).get('stock',0)
        print(f'  🔥 {i[\"name\"][:35]}  ¥{i[\"price\"]}  库存: {old}→{i[\"stock\"]}  [{i[\"theme\"]}]')
    print()

if new_items:
    print(f'🆕 [{now}] 新商品:')
    for i in new_items:
        icon = '🟢' if i['stock']>0 else '🔴'
        print(f'  {icon} {i[\"name\"][:35]}  ¥{i[\"price\"]}  [{i[\"theme\"]}]')
    print()

if not restocked and not new_items:
    print(f'  ⏳ [{now}] 送团圆/送伴侣 {len(watched_soldout)} 件售罄, 暂无变化')

with open(sf,'w') as f: json.dump(curr, f, ensure_ascii=False)
print(f'__RESTOCKED__:{len(restocked)}')

if restocked:
    lines = []
    for i in restocked:
        old = prev.get(i['id'],{}).get('stock',0)
        lines.append(f'{i[\"name\"]} ¥{i[\"price\"]} 库存:{old}→{i[\"stock\"]} [{i[\"theme\"]}]')
    print('__RESTOCK_DETAIL__:' + '|'.join(lines))
"
}

# ======== 主入口 ========

if [ "${1:-}" = "--loop" ]; then
    echo "================================================"
    echo "  深圳工会 · 商品库存监控"
    echo "  盯: ${WATCH_THEMES[*]}"
    echo "  策略: 常规${NORMAL_BASE}s / 高峰${PEAK_BASE}s / 退单${RUSH_INTERVAL}s"
    echo "  通知: ${MAIL_TO}"
    echo "  Ctrl+C 停止"
    echo "================================================"
    echo ""

    # 测试邮件
    echo "📧 测试邮件连接..."
    send_mail "深工惠监控已启动" "监控脚本已于 $(date '+%Y-%m-%d %H:%M:%S') 启动，盯: ${WATCH_THEMES[*]}。检测到退单时将自动发送邮件通知。"
    echo ""

    # 首次全量
    echo "🔍 $(date '+%Y-%m-%d %H:%M:%S') 首次全量扫描..."
    echo ""
    ITEMS=$(fetch_all_items)
    RESULT=$(report_full "$ITEMS")
    echo "$RESULT" | grep -v '^__RESTOCKED__\|^__RESTOCK_DETAIL__'
    echo ""

    RUSH_UNTIL=0
    RC=$(echo "$RESULT" | grep '^__RESTOCKED__' | cut -d: -f2)
    if [ "${RC:-0}" -gt 0 ]; then
        RUSH_UNTIL=$(python3 -c "import time; print(int(time.time())+${RUSH_DURATION})")
        echo "⚡ 进入加速模式 (${RUSH_INTERVAL}s/轮, 持续${RUSH_DURATION}s)"
        # 发邮件
        DETAIL=$(echo "$RESULT" | grep '^__RESTOCK_DETAIL__' | cut -d: -f2- | tr '|' '\n')
        send_mail "🚨深工惠 有人退单!" "$DETAIL"
    fi

    echo "────────────────────────────────────"
    echo "  开始循环监控"
    echo "────────────────────────────────────"

    PREV_MODE=""
    while true; do
        IV_INFO=$(calc_interval "$RUSH_UNTIL")
        IV=$(echo "$IV_INFO" | cut -d' ' -f1)
        MODE=$(echo "$IV_INFO" | cut -d' ' -f2)

        case "$MODE" in
            RUSH) ;;
            PEAK) [ "$PREV_MODE" != "PEAK" ] && echo "  🔥 进入高峰时段 (${PEAK_BASE}s±${PEAK_JITTER}s)" ;;
            NORMAL)
                [ "$PREV_MODE" = "RUSH" ] && echo "  ⏸️  加速结束, 恢复常规轮询"
                ;;
        esac
        PREV_MODE="$MODE"

        sleep "$IV"

        ITEMS=$(fetch_all_items)
        if [ -z "$ITEMS" ]; then
            echo "  ⚠️  [$(date '+%H:%M:%S')] 拉取失败, 跳过"
            continue
        fi

        RESULT=$(report_watch "$ITEMS")
        echo "$RESULT" | grep -v '^__RESTOCKED__\|^__RESTOCK_DETAIL__'

        RC=$(echo "$RESULT" | grep '^__RESTOCKED__' | cut -d: -f2)
        if [ "${RC:-0}" -gt 0 ]; then
            RUSH_UNTIL=$(python3 -c "import time; print(int(time.time())+${RUSH_DURATION})")
            echo "  ⚡ 检测到退单! 加速${RUSH_INTERVAL}s/轮, 持续${RUSH_DURATION}s"
            echo -e '\a'

            # 发邮件通知
            DETAIL=$(echo "$RESULT" | grep '^__RESTOCK_DETAIL__' | cut -d: -f2- | tr '|' '\n')
            send_mail "🚨深工惠 有人退单!" "$(date '+%Y-%m-%d %H:%M:%S') 检测到库存恢复:

${DETAIL}

请尽快打开小程序抢购!"
        fi
    done
else
    echo "================================================"
    echo "  深圳工会 · 商品库存监控 (单次)"
    echo "================================================"
    echo ""
    echo "🔍 $(date '+%Y-%m-%d %H:%M:%S') 开始扫描..."
    echo ""
    ITEMS=$(fetch_all_items)
    RESULT=$(report_full "$ITEMS")
    echo "$RESULT" | grep -v '^__RESTOCKED__\|^__RESTOCK_DETAIL__'
    echo ""
    echo "======== 完成 $(date '+%H:%M:%S') ========"
fi