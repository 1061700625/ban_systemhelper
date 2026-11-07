#!/data/data/com.termux/files/usr/bin/bash
# SystemHelper 限制脚本 v3 — Termux + rish (Shizuku/ADB shell)，无需 root
# v3 修正：getprop 引号 bug（曾刷出全量系统属性）、过滤无效用户、Chain3 原始值诊断
# 用法: bash systemhelper.sh <命令> [full]   ；执行 `bash systemhelper.sh help` 看完整说明
# 环境变量: RISH=/path/to/rish  USERS="0 10"  QUIET=1（只打印失败项）
PKG=com.mobiletools.systemhelper
LOG=$HOME/systemhelper-limit.log

show_help() {
cat <<'EOF'
SystemHelper 限制脚本 — Termux + rish (Shizuku/ADB shell)，无需 root
目标包: com.mobiletools.systemhelper

用法: bash systemhelper.sh <命令> [full]

命令：
  check / verify   只读体检，检查挂起、停止、后台限制与断网是否生效。
  limit            应用全部限制（撤权限、禁组件、挂起、断网），末尾自动体检。
  limit full       在 limit 之上再整包禁用，最彻底，建议先观察 1-2 天。
  restore          一键回滚全部改动，并按「恢复态」体检。
  net              只重设 Chain3 断网，每次重启后都要重跑。
  alarm            打开「闹钟和提醒」设置页，供手动关闭精确闹钟权限。
  diag             打印 Chain3 各命令的原始返回值（会顺带执行一次断网）。
  help             显示本说明。

环境变量：RISH=/path/to/rish 指定 rish；USERS="0 10" 指定用户；QUIET=1 只打印失败项。
流程：check → limit →（手动关闹钟权限）→ check → 重启后 net → limit full → 需要时 restore。
注意：Chain3 需 ROM 支持，不支持时改用 NetGuard/RethinkDNS 或拦截 dm.wo.com.cn；日志在 ~/systemhelper-limit.log。
EOF
}

# help / 未知命令直接显示说明，不需要 Shizuku 就绪
case "${1:-}" in
  check|verify|limit|restore|net|alarm|diag) ;;
  *) show_help; exit 0 ;;
esac

[ -n "$RISH" ] || { [ -x ./rish ] && RISH=./rish || RISH=$(command -v rish); }
[ -n "$RISH" ] || { echo "找不到 rish：请先从 Shizuku「在终端应用中使用」导出并 chmod +x"; exit 1; }

# 用 $* 拼接，避免漏引号时只执行第一个单词
sh_cmd() { "$RISH" -c "$*" 2>&1 | tr -d '\r'; }
is_err() { echo "$1" | grep -qiE 'error|exception|failure|unknown|denied|not found|invalid|cannot|usage:'; }
try_q() { o=$(sh_cmd "$1"); printf '%s\n' "$1 :: $o" >> "$LOG"; ! is_err "$o"; }
try() {
  [ "$QUIET" = 1 ] || printf '  %s\n' "$1"
  o=$(sh_cmd "$1"); printf '%s\n' "$1 :: $o" >> "$LOG"
  if is_err "$o"; then echo "    [失败] $(echo "$o" | head -1)"; return 1; fi
  [ "$QUIET" = 1 ] || echo "    [OK]"
  return 0
}

R=(OnBootReceiver ScheduleRegisterReceiver SignalInfoRegisterReceiver AppInfoRegisterReceiver GetSignalInfoReceiver SIMStateReceiver ConnectStateReceiver)
P=(android.permission.ACCESS_BACKGROUND_LOCATION android.permission.ACCESS_FINE_LOCATION android.permission.ACCESS_COARSE_LOCATION android.permission.READ_PHONE_STATE android.permission.BLUETOOTH_CONNECT)
O=(GET_USAGE_STATS RUN_IN_BACKGROUND RUN_ANY_IN_BACKGROUND SCHEDULE_EXACT_ALARM)

WHO=$(sh_cmd whoami)
echo "rish 身份: $WHO   厂商: $(sh_cmd "getprop ro.product.manufacturer")"
case "$WHO" in *shell*|*root*) ;; *) echo "Shizuku 未就绪或未授权，请先启动 Shizuku"; exit 1 ;; esac
sh_cmd "pm path $PKG" | grep -q package: || { echo "未找到 $PKG，请核对包名"; exit 1; }

# 只保留确实安装了本包的用户（排除 999 这类系统占位/无该包的用户）
DPKG=$(sh_cmd "dumpsys package $PKG")
if [ -n "$USERS" ]; then ULIST="$USERS"; else
  ULIST=$(sh_cmd "pm list users" | grep -oE 'UserInfo.[0-9]+' | grep -oE '[0-9]+' | tr '\n' ' ')
  [ -z "$ULIST" ] && ULIST=0
fi
KEEP=""
for u in $ULIST; do
  pp=$(sh_cmd "pm path --user $u $PKG")
  if echo "$pp" | grep -q '^package:'; then
    KEEP="$KEEP $u"
  elif echo "$pp" | grep -qiE 'package not found|not installed'; then
    echo "  （忽略 User $u：该用户下未安装此包）"
  elif is_err "$pp"; then
    KEEP="$KEEP $u"   # pm path 不支持 --user 等命令级错误，保守保留
  else
    echo "  （忽略 User $u：pm path 无输出）"
  fi
done
ULIST=$(echo $KEEP)
[ -z "$ULIST" ] && ULIST=0
echo "目标用户: $ULIST"

# Chain3 回读值不一定是字面 true/false，统一按语义解析
val_off() { echo "$1" | grep -qiE 'false|disabled|\b0\b|\bdeny|blocked|\boff\b'; }
val_on()  { echo "$1" | grep -qiE 'true|enabled|\b1\b|\ballow|\bon\b'; }
probe_chain() {
  CR=$(sh_cmd "cmd connectivity get-chain3-enabled")
  if is_err "$CR"; then CHAIN_OK=0; else CHAIN_OK=1; fi
}
chain_set() {
  s=$1; ok=0
  for u in $ULIST; do
    try_q "cmd connectivity set-package-networking-enabled $s $PKG --user $u" && ok=1
  done
  [ $ok -eq 0 ] && try_q "cmd connectivity set-package-networking-enabled $s $PKG" && ok=1
  return $((1 - ok))
}
chain_get() {
  p=$(sh_cmd "cmd connectivity get-package-networking-enabled $PKG --user $1")
  if is_err "$p"; then p=$(sh_cmd "cmd connectivity get-package-networking-enabled $PKG"); fi
  echo "$p"
}
apply_net() {
  echo "[断网] 启用 Chain3 防火墙框架"
  o=$(sh_cmd "cmd connectivity set-chain3-enabled true")
  printf '%s\n' "cmd connectivity set-chain3-enabled true :: $o" >> "$LOG"
  echo "    返回: ${o:-（无输出）}"
  if is_err "$o"; then
    CHAIN_OK=0
    echo "    ⚠️ 该 ROM/Android 版本不支持 Chain3，跳过内核断网"
    echo "       降级：装 NetGuard/RethinkDNS 按应用禁网，或私人DNS/路由器拦截 dm.wo.com.cn"
  else
    CHAIN_OK=1
    chain_set false && echo "    [OK] 已按应用禁止联网" || echo "    [失败] 按应用开关未生效，请执行 diag 查看原始返回"
  fi
  # INTERNET appop 在 AOSP 无对应项，仅尽力而为，不计入校验
  for u in $ULIST; do try_q "cmd appops set --user $u $PKG INTERNET deny"; done
}

check_state() {
  mode=$1; total=0; skipped=0
  DPKG=$(sh_cmd "dumpsys package $PKG")
  probe_chain
  for u in $ULIST; do
    echo "----- User $u -----"
    fail=0
    d=$(echo "$DPKG" | grep "User $u:" | head -1)
    if [ -z "$d" ]; then
      echo "  ⚠️ 未读到 User $u 状态，跳过校验"
      skipped=$((skipped + 1)); continue
    fi
    if [ "$mode" = limit ]; then
      echo "$d" | grep -q 'suspended=true' && echo "  ✅ 已挂起" || { echo "  ❌ 未挂起"; fail=1; }
      echo "$d" | grep -q 'stopped=true' && echo "  ✅ 已停止" || echo "  ⚠️ 非 stopped（force-stop 状态易变，仅供参考）"
    else
      echo "$d" | grep -q 'suspended=true' && { echo "  ❌ 仍处于挂起"; fail=1; } || echo "  ✅ 已解除挂起"
    fi
    a=$(sh_cmd "cmd appops get --user $u $PKG RUN_ANY_IN_BACKGROUND")
    if [ "$mode" = limit ]; then
      echo "$a" | grep -qi ignore && echo "  ✅ 后台运行已禁" || { echo "  ❌ 后台运行未禁"; fail=1; }
    else
      echo "$a" | grep -qi ignore && { echo "  ❌ 后台仍受限"; fail=1; } || echo "  ✅ 后台已恢复"
    fi
    if [ "$CHAIN_OK" -eq 1 ]; then
      c=$CR; p=$(chain_get $u)
      if [ "$mode" = limit ]; then
        if val_off "$c"; then echo "  ❌ Chain3 框架未启用（断网不会生效）  原始值: $c"; fail=1
        elif val_on "$c"; then echo "  ✅ Chain3 框架已启用"
        else echo "  ⚠️ 框架状态无法解析，原始值: $c（请执行 diag）"; fi
        if val_off "$p"; then echo "  ✅ 按应用联网已关闭"
        elif val_on "$p"; then echo "  ❌ 按应用联网仍开启  原始值: $p"; fail=1
        else echo "  ⚠️ 联网状态无法解析，原始值: $p（请执行 diag）"; fi
      else
        val_on "$p" && echo "  ✅ 已恢复联网" || { echo "  ❌ 联网未恢复  原始值: $p"; fail=1; }
      fi
    else
      echo "  ⚠️ Chain3 不可用，联网状态无法用命令验证，请自行抓包确认"
    fi
    [ $fail -eq 0 ] && echo "  👉 User $u：通过" || { echo "  👉 User $u：存在失败项"; total=1; }
  done
  echo "跳过用户数: $skipped（跳过≠通过）"
  return $total
}

case "$1" in
help) show_help ;;
check|verify)
  check_state limit && echo "🎉 全部通过" || echo "⚠️ 存在未通过项，请重新执行 limit 或 diag"
  ;;
limit)
  echo "[1/6] 撤销运行时权限 + AppOps"
  for u in $ULIST; do
    for p in "${P[@]}"; do try "pm revoke --user $u $PKG $p"; done
    for o in "${O[@]}"; do try "cmd appops set --user $u $PKG $o ignore"; done
  done
  echo "[2/6] 同意开关（仅 vivo 机型有效）"
  m=$(sh_cmd "getprop ro.product.manufacturer" | tr 'A-Z' 'a-z')
  if [ "$m" = vivo ]; then try "settings put secure operator_service_improve_plan 0"
  else echo "  厂商=$m：代码只读 device_provisioned，该开关无效，跳过"; fi
  echo "[3/6] 组件级禁用，切断自启链"
  for u in $ULIST; do for c in "${R[@]}"; do try "pm disable --user $u $PKG/.control.$c"; done; done
  echo "[4/6] 挂起 + 强制停止"
  for u in $ULIST; do try "pm suspend --user $u $PKG"; try "am force-stop --user $u $PKG"; done
  echo "[5/6] 断网"; apply_net
  echo "[6/6] 打开闹钟和提醒设置页 + 可选整包禁用"
  try "am start -a android.settings.REQUEST_SCHEDULE_EXACT_ALARM -d package:$PKG"
  if [ "$2" = full ]; then for u in $ULIST; do try "pm disable-user --user $u $PKG"; done
  else echo "  整包未禁用（观察 1–2 天无异常后可加参数 full）"; fi
  echo "完成：请手动关闭『闹钟和提醒』，再执行 check。日志: $LOG"
  echo "⚠️ 重启后 Chain3 规则会被清空，需执行: bash $0 net"
  echo; check_state limit || true
  ;;
restore)
  echo "回滚全部改动"
  for u in $ULIST; do
    try "pm unsuspend --user $u $PKG"
    try "pm enable --user $u $PKG"
    for c in "${R[@]}"; do try "pm enable --user $u $PKG/.control.$c"; done
    for o in "${O[@]}"; do try "cmd appops set --user $u $PKG $o default"; done
    for p in "${P[@]}"; do try "pm grant --user $u $PKG $p"; done
    try "cmd appops set --user $u $PKG INTERNET default"
  done
  try_q "cmd connectivity set-chain3-enabled true" && { chain_set true && echo "  [OK] 已恢复联网"; } || echo "  [跳过] Chain3 不可用"
  try "settings delete secure operator_service_improve_plan"
  for u in $ULIST; do try "am force-stop --user $u $PKG"; done
  echo "已回滚，建议重启设备"
  echo; check_state restore || true
  ;;
net)
  apply_net
  echo "如需恢复联网: bash $0 restore"
  ;;
alarm)
  try "am start -a android.settings.REQUEST_SCHEDULE_EXACT_ALARM -d package:$PKG"
  ;;
diag)
  echo "== 设备信息 =="
  echo "Android $(sh_cmd "getprop ro.build.version.release") / SDK $(sh_cmd "getprop ro.build.version.sdk")"
  echo "== pm list users =="; sh_cmd "pm list users"
  echo "== cmd connectivity 帮助 =="; sh_cmd "cmd connectivity help" | head -40
  echo "== Chain3 原始回读（注意：下面会顺带执行 set，等同 net）=="
  echo "get-chain3-enabled          : $(sh_cmd "cmd connectivity get-chain3-enabled")"
  echo "set-chain3-enabled true     : $(sh_cmd "cmd connectivity set-chain3-enabled true")"
  echo "get-chain3-enabled (再次)   : $(sh_cmd "cmd connectivity get-chain3-enabled")"
  echo "get-package-networking      : $(sh_cmd "cmd connectivity get-package-networking-enabled $PKG")"
  echo "set false                   : $(sh_cmd "cmd connectivity set-package-networking-enabled false $PKG")"
  echo "get-package-networking(再次): $(sh_cmd "cmd connectivity get-package-networking-enabled $PKG")"
  echo "== appops =="
  echo "RUN_ANY_IN_BACKGROUND: $(sh_cmd "cmd appops get --user 0 $PKG RUN_ANY_IN_BACKGROUND")"
  echo "INTERNET             : $(sh_cmd "cmd appops get --user 0 $PKG INTERNET")"
  ;;
*) show_help ;;
esac
