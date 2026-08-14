#!/bin/sh
# TrollShot daemon 启动包装脚本
# launchd 直接启动 trollshotd 二进制会被 iOS 系统杀掉(SIGKILL)，
# 通过 /bin/sh 包装脚本 fork 出来则不会，这是 iOS 越狱环境的已知行为。
# 保持脚本存活，daemon 崩溃时自动重启。
# 检查 /var/mobile/trollshot/stop.flag 标志，存在则不启动 daemon（用户通过 app 停止）

DEBUG_FLAG="/var/mobile/trollshot/debug_mode"
LOG_FILE="/var/mobile/trollshot/trollshotd.log"

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
        else
            # 非调试模式：丢弃日志输出
            /usr/bin/trollshotd --port 6688 > /dev/null 2>&1
        fi
    fi
    sleep 1
done
