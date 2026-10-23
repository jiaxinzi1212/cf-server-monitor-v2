#!/usr/bin/env bash
set -euo pipefail

export HOME="${HOME:-/root}"
RUNNER=/usr/local/bin/cfsm-nodequality
SERVICE=/etc/systemd/system/cfsm-nodequality.service
TIMER=/etc/systemd/system/cfsm-nodequality.timer
CRON_FILE=/etc/cron.d/cfsm-nodequality
STATE_DIR=/var/lib/cfsm-nodequality
LOG_FILE=/var/log/cfsm-nodequality.log

if [ "$(id -u)" -ne 0 ]; then
  echo "[ERROR] 请使用 root 运行" >&2
  exit 1
fi

for cmd in bash curl grep sed awk date mktemp; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "[ERROR] 缺少依赖：$cmd" >&2
    exit 1
  }
done

find_probe_config() {
  for file in \
    /etc/config/cf-probe/config.conf \
    /root/.cf-probe/config.conf \
    "${HOME:-/root}/.cf-probe/config.conf"
  do
    if [ -f "$file" ]; then
      printf '%s\n' "$file"
      return 0
    fi
  done
  return 1
}

PROBE_CONFIG="$(find_probe_config || true)"
if [ -z "$PROBE_CONFIG" ]; then
  echo "[ERROR] 没找到 cf-probe 配置 config.conf，请先安装 cf-probe。" >&2
  exit 1
fi

if [ -f "$RUNNER" ] && ! grep -q 'IPQuality-only test started' "$RUNNER" 2>/dev/null; then
  cp -a "$RUNNER" "$RUNNER.full-backup"
  echo "[INFO] 已备份原 NQ 脚本：$RUNNER.full-backup"
fi

rm -rf /.nodequality20* /var/tmp/nodequality 2>/dev/null || true
rm -rf /tmp/NodeQuality* /tmp/BenchOS* /tmp/IPQuality* 2>/dev/null || true

cat > "$RUNNER" <<'RUNNER_EOF'
#!/usr/bin/env bash
set -u
export HOME="${HOME:-/root}"

LOG_FILE=/var/log/cfsm-nodequality.log
LOCK_DIR=/tmp/cfsm-nodequality.lock
STATE_DIR=/var/lib/cfsm-nodequality
LAST_RUN_FILE="$STATE_DIR/last-scheduled-success"
SCHEDULED=0
TMP_DIR=""
[ "${1:-}" = "--scheduled" ] && SCHEDULED=1

find_probe_config() {
  for file in \
    /etc/config/cf-probe/config.conf \
    /root/.cf-probe/config.conf \
    "${HOME:-/root}/.cf-probe/config.conf"
  do
    if [ -f "$file" ]; then
      printf '%s\n' "$file"
      return 0
    fi
  done
  return 1
}

read_config_value() {
  key="$1"
  file="$2"
  line="$(grep -m1 "^${key}=" "$file" 2>/dev/null || true)"
  value="${line#*=}"
  value="${value#\"}"
  value="${value%\"}"
  printf '%s' "$value"
}

cleanup() {
  rm -rf "$LOCK_DIR" 2>/dev/null || true
  if [ -n "${TMP_DIR:-}" ]; then
    rm -rf "$TMP_DIR" 2>/dev/null || true
  fi
}

mkdir -p "$STATE_DIR"

if [ "$SCHEDULED" -eq 1 ]; then
  BJ_DAY="$(TZ='CST-8' date '+%d')"
  BJ_HOUR="$(TZ='CST-8' date '+%H')"
  BJ_STAMP="$(TZ='CST-8' date '+%Y%m%d')"
  if { [ "$BJ_DAY" != "01" ] && [ "$BJ_DAY" != "15" ]; } || [ "$BJ_HOUR" != "03" ]; then
    exit 0
  fi
  if [ -f "$LAST_RUN_FILE" ] && [ "$(cat "$LAST_RUN_FILE" 2>/dev/null || true)" = "$BJ_STAMP" ]; then
    exit 0
  fi
fi

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "[$(date '+%F %T')] IPQuality already running; skip." >> "$LOG_FILE"
  exit 0
fi
trap cleanup EXIT INT TERM

PROBE_CONFIG="$(find_probe_config || true)"
if [ -z "$PROBE_CONFIG" ]; then
  echo "[$(date '+%F %T')] ERROR: cf-probe config not found" >> "$LOG_FILE"
  exit 1
fi

SERVER_ID="$(read_config_value SERVER_ID "$PROBE_CONFIG")"
SECRET="$(read_config_value SECRET "$PROBE_CONFIG")"
WORKER_URL="$(read_config_value WORKER_URL "$PROBE_CONFIG")"

if [ -z "$SERVER_ID" ] || [ -z "$SECRET" ] || [ -z "$WORKER_URL" ]; then
  echo "[$(date '+%F %T')] ERROR: invalid cf-probe config" >> "$LOG_FILE"
  exit 1
fi

BASE_URL="${WORKER_URL%/}"
BASE_URL="${BASE_URL%/update}"
REPORT_ENDPOINT="${BASE_URL}/api/nq-report"
TMP_DIR="$(mktemp -d /tmp/cfsm-ipquality.XXXXXX)"
IP_SCRIPT="$TMP_DIR/ip.sh"
TMP_OUTPUT="$TMP_DIR/ipquality.log"

{
  echo
  echo "============================================================"
  echo "[$(date '+%F %T')] IPQuality-only test started"
  echo "server_id=$SERVER_ID"
  echo "--- lightweight system snapshot ---"
  uname -a 2>/dev/null || true
  awk '/MemTotal|MemAvailable|SwapTotal|SwapFree/ {print}' /proc/meminfo 2>/dev/null || true
  df -h / 2>/dev/null || true
} >> "$LOG_FILE"

if ! curl -fL --retry 3 --connect-timeout 15 --max-time 90 \
  https://raw.githubusercontent.com/xykt/IPQuality/main/ip.sh \
  -o "$IP_SCRIPT" >> "$LOG_FILE" 2>&1; then
  echo "[$(date '+%F %T')] ERROR: failed to download IPQuality" >> "$LOG_FILE"
  exit 1
fi

set +e
(
  cd "$TMP_DIR" || exit 1
  HOME=/root bash "$IP_SCRIPT" -4 -y
) > "$TMP_OUTPUT" 2>&1
TEST_RC=$?
set -e

cat "$TMP_OUTPUT" >> "$LOG_FILE"
REPORT_URL="$(grep -Eio 'https://report\.check\.place/ip/[A-Za-z0-9_-]+\.svg' "$TMP_OUTPUT" | tail -n 1 || true)"

if [ -z "$REPORT_URL" ]; then
  echo "[$(date '+%F %T')] ERROR: IPQuality report URL not found (exit=$TEST_RC)" >> "$LOG_FILE"
  exit 1
fi

TESTED_AT="$(date +%s)"
PAYLOAD="$(printf '{\"id\":\"%s\",\"secret\":\"%s\",\"report_url\":\"%s\",\"tested_at\":%s}' \
  "$SERVER_ID" "$SECRET" "$REPORT_URL" "$TESTED_AT")"

if curl -fsS --retry 3 --connect-timeout 15 \
  -X POST "$REPORT_ENDPOINT" \
  -H 'Content-Type: application/json' \
  --data "$PAYLOAD" >> "$LOG_FILE" 2>&1; then
  echo >> "$LOG_FILE"
  echo "[$(date '+%F %T')] uploaded: $REPORT_URL" >> "$LOG_FILE"
  if [ "$SCHEDULED" -eq 1 ]; then
    printf '%s\n' "$BJ_STAMP" > "$LAST_RUN_FILE"
  fi
  printf '%s\n' "$REPORT_URL"
else
  echo >> "$LOG_FILE"
  echo "[$(date '+%F %T')] ERROR: failed to upload report to $REPORT_ENDPOINT" >> "$LOG_FILE"
  exit 1
fi
RUNNER_EOF

chmod 700 "$RUNNER"
mkdir -p "$STATE_DIR"

MEM_KB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
SWAP_KB="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
if [ -n "$MEM_KB" ] && [ "$MEM_KB" -lt 196608 ] && { [ -z "$SWAP_KB" ] || [ "$SWAP_KB" -eq 0 ]; }; then
  echo "[WARN] 当前内存低于 192MB 且无 Swap；IPQuality 通常可运行，但建议保留约 128-256MB Swap 作为保险。"
fi

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  cat > "$SERVICE" <<EOF
[Unit]
Description=CF Server Monitor IPQuality Lite test
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=HOME=/root
ExecStart=$RUNNER
TimeoutStartSec=20min
Nice=10
EOF

  cat > "$TIMER" <<'TIMER_EOF'
[Unit]
Description=Run CFSM IPQuality Lite on the 1st and 15th at 03:00 Asia/Shanghai

[Timer]
OnCalendar=*-*-01,15 03:00:00 Asia/Shanghai
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
TIMER_EOF

  systemctl daemon-reload
  systemctl enable --now cfsm-nodequality.timer
  rm -f "$CRON_FILE"

  echo "[OK] IPQuality Lite 定时任务已安装（systemd）"
  echo "     时间：每月 1 日、15 日，北京时间 03:00"
  systemctl list-timers cfsm-nodequality.timer --no-pager || true
elif [ -d /etc/cron.d ]; then
  cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/10 * * * * root $RUNNER --scheduled
EOF
  chmod 644 "$CRON_FILE"
  echo "[OK] IPQuality Lite 定时任务已安装（cron.d fallback）"
  echo "     每 10 分钟检查一次，仅在北京时间每月 1/15 日 03 点真正执行。"
else
  echo "[ERROR] 未检测到 systemd 或 /etc/cron.d，无法创建定时任务。" >&2
  exit 1
fi

echo "[INFO] cf-probe 配置：$PROBE_CONFIG"
echo "[INFO] 执行脚本：$RUNNER"
echo "[INFO] 日志：$LOG_FILE"
echo
echo "立即测试一次："
echo "  systemctl start cfsm-nodequality.service  # systemd"
echo "  或：HOME=/root $RUNNER"
echo
echo "查看日志："
echo "  tail -n 100 $LOG_FILE"
