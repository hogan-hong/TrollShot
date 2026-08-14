#!/bin/sh
# TrollShot daemon 启动包装脚本
# launchd 直接启动 trollshotd 二进制会被 iOS 系统杀掉(SIGKILL)，
# 通过 /bin/sh 包装脚本 fork 出来则不会，这是 iOS 越狱环境的已知行为。
# 保持脚本存活，daemon 崩溃时自动重启。
# 检查 /var/mobile/trollshot/stop.flag 标志，存在则不启动 daemon（用户通过 app 停止）

DEBUG_FLAG="/var/mobile/trollshot/debug_mode"
LOG_FILE="/var/mobile/trollshot/trollshotd.log"
WRAPPER_LOG="/var/mobile/trollshot/wrapper.log"

# 开机/启动时清除停止标志——stop.flag 仅作为运行时停止信号，不跨重启持久化。
# 重启后 wrapper 总是自动启动 daemon，用户无需手动开启服务。
rm -f /var/mobile/trollshot/stop.flag

# 简单的启动日志（不受调试模式控制，方便排查开机自启问题）
echo "[$(date '+%Y-%m-%d %H:%M:%S')] wrapper 启动，清除 stop.flag" >> "$WRAPPER_LOG" 2>/dev/null

# 检查调试模式是否开启
is_debug() {
    [ -f "$DEBUG_FLAG" ] && [ "$(cat "$DEBUG_FLAG" 2>/dev/null)" = "1" ]
}

while true; do
    if [ ! -f /var/mobile/trollshot/stop.flag ]; then
        if is_debug; then
            # 调试模式：重定向日志到文件，启动前清空旧日志（避免无限增长）
            > "$LOG_FILE"
            /usr/bin/trollshotd --port 6688 >> "$LOG_FILE" 2>&1
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] trollshotd 退出(调试模式)，1秒后重启" >> "$WRAPPER_LOG" 2>/dev/null
        else
            # 非调试模式：丢弃日志输出
            /usr/bin/trollshotd --port 6688 > /dev/null 2>&1
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] trollshotd 退出，1秒后重启" >> "$WRAPPER_LOG" 2>/dev/null
        fi
    else
        # stop.flag 存在，等待用户通过 app 重新启动（app 会删除 stop.flag）
        :
    fi
    sleep 1
done
