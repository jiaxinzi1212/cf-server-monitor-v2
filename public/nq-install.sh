#!/usr/bin/env bash
set -euo pipefail

RUNNER=/usr/local/bin/cfsm-nodequality
SERVICE=/etc/systemd/system/cfsm-nodequality.service
TIMER=/etc/systemd/system/cfsm-nodequality.timer
CRON_FILE=/etc/cron.d/cfsm-nodequality

if [ "$(id -u)" -ne 0 ]; then
  echo "[ERROR] 请使用 root 运行：sudo bash nq-install.sh" >&2
  exit 1
fi

for cmd in bash curl grep sed; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "[ERROR] 缺少依赖：$cmd" >&2
    exit 1
  }
done

find_probe_config() {
  for file in \
    /etc/config/cf-probe/config.conf \
    /root/.cf-probe/config.conf \
    "$HOME/.cf-probe/config.conf"
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
  echo "[ERROR] 没找到新 CF 探针配置 config.conf。请先安装 cf-probe。" >&2
  exit 1
fi

cat > "$RUNNER" <<'RUNNER_EOF'
#!/usr/bin/env bash
set -u

LOG_FILE=/var/log/cfsm-nodequality.log
LOCK_DIR=/tmp/cfsm-nodequality.lock

find_probe_config() {
  for file in \
    /etc/config/cf-probe/config.conf \
    /root/.cf-probe/config.conf \
    "$HOME/.cf-probe/config.conf"
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
}

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "[$(date '+%F %T')] NodeQuality already running; skip." >> "$LOG_FILE"
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
TMP_OUTPUT="$(mktemp /tmp/cfsm-nodequality.XXXXXX)"
trap 'rm -f "$TMP_OUTPUT"; cleanup' EXIT INT TERM

{
  echo
  echo "============================================================"
  echo "[$(date '+%F %T')] NodeQuality test started"
  echo "server_id=$SERVER_ID"
} >> "$LOG_FILE"

# 与已经人工验证成功的模式保持一致：基础信息=是、IP质量=是、网络质量=低流量、回程=是。
set +e
printf 'y\ny\nl\ny\n' | bash <(curl -fsSL --retry 3 --connect-timeout 15 https://run.NodeQuality.com) >"$TMP_OUTPUT" 2>&1
TEST_RC=$?
set -e

cat "$TMP_OUTPUT" >> "$LOG_FILE"
REPORT_URL="$(grep -Eo 'https://nodequality\.com/r/[A-Za-z0-9_-]+' "$TMP_OUTPUT" | tail -n 1 || true)"

if [ -z "$REPORT_URL" ]; then
  echo "[$(date '+%F %T')] ERROR: NodeQuality report URL not found (exit=$TEST_RC)" >> "$LOG_FILE"
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
  printf '%s\n' "$REPORT_URL"
else
  echo >> "$LOG_FILE"
  echo "[$(date '+%F %T')] ERROR: failed to upload report to $REPORT_ENDPOINT" >> "$LOG_FILE"
  exit 1
fi
RUNNER_EOF

chmod 700 "$RUNNER"

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  cat > "$SERVICE" <<EOF
[Unit]
Description=CF Server Monitor NodeQuality test
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$RUNNER
EOF

  cat > "$TIMER" <<'EOF'
[Unit]
Description=Run NodeQuality on the 1st and 15th at 03:00 Asia/Shanghai

[Timer]
OnCalendar=*-*-01,15 03:00:00 Asia/Shanghai
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now cfsm-nodequality.timer
  rm -f "$CRON_FILE"

  echo "[OK] NodeQuality 定时任务已安装（systemd）"
  echo "     时间：每月 1 日、15 日，北京时间 03:00"
  systemctl list-timers cfsm-nodequality.timer --no-pager || true
else
  cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CRON_TZ=Asia/Shanghai
0 3 1,15 * * root $RUNNER
EOF
  chmod 644 "$CRON_FILE"

  echo "[OK] NodeQuality 定时任务已安装（cron）"
  echo "     时间：每月 1 日、15 日，北京时间 03:00"
  echo "[WARN] 当前系统无 systemd，请确认 crond 支持 CRON_TZ=Asia/Shanghai。"
fi

echo "[INFO] cf-probe 配置：$PROBE_CONFIG"
echo "[INFO] 执行脚本：$RUNNER"
echo "[INFO] 日志：/var/log/cfsm-nodequality.log"
echo
echo "立即测试一次："
echo "  $RUNNER"
echo
echo "查看日志："
echo "  tail -n 80 /var/log/cfsm-nodequality.log"
