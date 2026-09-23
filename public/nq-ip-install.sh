#!/usr/bin/env bash
set -euo pipefail

export HOME="${HOME:-/root}"
RUNNER=/usr/local/bin/cfsm-nodequality
CRON_FILE=/etc/crontabs/root
LOCAL_START=/etc/local.d/cfsm-crond.start

if [ "$(id -u)" -ne 0 ]; then
  echo "[ERROR] 请使用 root 运行" >&2
  exit 1
fi

for cmd in bash curl grep sed awk date; do
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
  echo "[ERROR] 没找到 cf-probe 配置 config.conf" >&2
  exit 1
fi

cat > "$RUNNER" <<'RUNNER_EOF'
#!/usr/bin/env bash
set -u
export HOME="${HOME:-/root}"

LOG_FILE=/var/log/cfsm-nodequality.log
LOCK_DIR=/tmp/cfsm-nodequality.lock
STATE_DIR=/var/lib/cfsm-nodequality
LAST_RUN_FILE="$STATE_DIR/last-scheduled-success"
SCHEDULED=0
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
  rm -rf "$LOCK_DIR" "$TMP_DIR" 2>/dev/null || true
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

TMP_DIR="$(mktemp -d /tmp/cfsm-ipquality.XXXXXX)"
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
IP_SCRIPT="$TMP_DIR/ip.sh"
TMP_OUTPUT="$TMP_DIR/ipquality.log"

{
  echo
  echo "============================================================"
  echo "[$(date '+%F %T')] IPQuality-only test started"
  echo "server_id=$SERVER_ID"
} >> "$LOG_FILE"

if ! curl -fL --retry 3 --connect-timeout 15 --max-time 90 \
  https://raw.githubusercontent.com/xykt/IPQuality/main/ip.sh \
  -o "$IP_SCRIPT" >> "$LOG_FILE" 2>&1; then
  echo "[$(date '+%F %T')] ERROR: failed to download IPQuality" >> "$LOG_FILE"
  exit 1
fi

set +e
HOME=/root bash "$IP_SCRIPT" -4 -y > "$TMP_OUTPUT" 2>&1
TEST_RC=$?
set -e

cat "$TMP_OUTPUT" >> "$LOG_FILE"
REPORT_URL="$(grep -Eo 'https://Report\.Check\.Place/ip/[A-Za-z0-9_-]+\.svg' "$TMP_OUTPUT" | tail -n 1 || true)"

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

mkdir -p /etc/crontabs
[ -f "$CRON_FILE" ] || touch "$CRON_FILE"
sed -i '/# CFSM_NODEQUALITY$/d;/cfsm-nodequality --scheduled/d' "$CRON_FILE" 2>/dev/null || true
printf '%s\n' "*/5 * * * * $RUNNER --scheduled # CFSM_NODEQUALITY" >> "$CRON_FILE"
chmod 600 "$CRON_FILE" 2>/dev/null || true

if command -v rc-update >/dev/null 2>&1; then
  rc-update add crond default >/dev/null 2>&1 || true
fi
if command -v rc-service >/dev/null 2>&1; then
  rc-service crond start >/dev/null 2>&1 || true
fi
sleep 1

if ! ps 2>/dev/null | grep -q '[c]rond'; then
  if [ -x /usr/sbin/crond ]; then
    /usr/sbin/crond -b -l 8 -L /var/log/crond.log -c /var/spool/cron/crontabs || true
  fi
fi

if command -v rc-update >/dev/null 2>&1 && [ -d /etc/local.d ]; then
  cat > "$LOCAL_START" <<'EOF'
#!/bin/sh
if ! ps 2>/dev/null | grep -q '[c]rond'; then
  /usr/sbin/crond -b -l 8 -L /var/log/crond.log -c /var/spool/cron/crontabs
fi
EOF
  chmod +x "$LOCAL_START"
  rc-update add local default >/dev/null 2>&1 || true
fi

echo "[OK] IPQuality-only NQ 定时任务已安装（Alpine/BusyBox cron）"
echo "     时间：每月 1 日、15 日，北京时间 03 点；每 5 分钟检查一次。"
echo "[INFO] cf-probe 配置：$PROBE_CONFIG"
echo "[INFO] 执行脚本：$RUNNER"
echo "[INFO] 日志：/var/log/cfsm-nodequality.log"
echo
echo "立即测试一次："
echo "  HOME=/root $RUNNER"
echo
echo "查看日志："
echo "  tail -n 100 /var/log/cfsm-nodequality.log"
