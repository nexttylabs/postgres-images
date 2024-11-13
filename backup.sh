#!/usr/bin/env bash
set -Eeo pipefail

HOOKS_DIR="/hooks"
if [ -d "${HOOKS_DIR}" ]; then
  on_error(){
    run-parts -a "error" "${HOOKS_DIR}"
  }
  trap 'on_error' ERR
fi

source "$(dirname "$0")/env.sh"

# 获取当前时间戳
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TODAY=$(date +%u)  # 获取星期几 (1-7)


# 日志函数
log() {
    echo "$1" | tee -a "$BACKUP_DIR/backup.log"
}

# 完整备份函数
full_backup() {
    BACKUP_NAME="${BACKUP_PREFIX}-full-${TIMESTAMP}"
    log "Starting full backup: $BACKUP_NAME"

    # 使用pg_basebackup的内置zstd压缩
    pg_basebackup \
        -h localhost \
        -U $POSTGRES_USER \
        -D "$BACKUP_DIR/full/$BACKUP_NAME" \
        -F tar \
        --compress=zstd \
        --wal-method=stream \
        --manifest-checksums=sha256 \
        --manifest-force-encode \
        --verbose \
        --progress \
        --label="full_backup_$TIMESTAMP"

    BACKUP_STATUS=$?

    if [ $BACKUP_STATUS -eq 0 ]; then
        # 保存manifest文件
        cp "$BACKUP_DIR/full/$BACKUP_NAME/backup_manifest" "$BACKUP_DIR/manifest/${BACKUP_NAME}_manifest"
        log "Full backup completed successfully"
    else
        log "Full backup failed with status $BACKUP_STATUS"
        exit 1
    fi
}

# 增量备份函数
incremental_backup() {
    BACKUP_NAME="${BACKUP_PREFIX}-incremental-${TIMESTAMP}"
    log "Starting incremental backup: $BACKUP_NAME"

    # 检查manifest目录是否为空
    if [ ! -d "$BACKUP_DIR/manifest" ] || [ -z "$(ls -A $BACKUP_DIR/manifest 2>/dev/null)" ]; then
        log "No manifest directory or empty manifest directory. Performing full backup instead."
        full_backup
        return
    fi

    # 安全地获取最近的全量备份WAL位置
    LATEST_FULL_MANIFEST=""
    if compgen -G "$BACKUP_DIR/manifest/*full*" > /dev/null; then
        LATEST_FULL_MANIFEST=$(ls -t "$BACKUP_DIR/manifest"/*full* 2>/dev/null | head -n 1)
    fi

    if [ -z "$LATEST_FULL_MANIFEST" ]; then
        log "No full backup manifest found. Performing full backup instead."
        full_backup
        return
    fi

    # 使用pg_basebackup的增量备份功能
    pg_basebackup \
        -h localhost \
        -U $PG_USER \
        -D "$BACKUP_DIR/incremental/$BACKUP_NAME" \
        -F tar \
        --compress=zstd \
        --wal-method=stream \
        --incremental \
        --incremental-wal-summarize \
        --manifest-checksums=sha256 \
        --manifest-force-encode \
        --verbose \
        --progress \
        --label="incremental_backup_$TIMESTAMP"

    BACKUP_STATUS=$?

    if [ $BACKUP_STATUS -eq 0 ]; then
        # 保存manifest文件
        cp "$BACKUP_DIR/incremental/$BACKUP_NAME/backup_manifest" "$BACKUP_DIR/manifest/${BACKUP_NAME}_manifest"
        log "Incremental backup completed successfully"
    else
        log "Incremental backup failed with status $BACKUP_STATUS"
        exit 1
    fi
}

# 验证备份函数
verify_backup() {
    local BACKUP_PATH=$1
    local BACKUP_TYPE=$2

    log "Verifying $BACKUP_TYPE backup: $(basename $BACKUP_PATH)"

    pg_verifybackup \
        --manifest-path="$BACKUP_PATH/backup_manifest" \
        --progress \
        "$BACKUP_PATH"

    if [ $? -eq 0 ]; then
        log "Backup verification successful"
        return 0
    else
        log "Backup verification failed"
        return 1
    fi
}

# 检查PostgreSQL服务是否运行（最多等待30秒）
check_postgres_running() {
    local max_attempts=30  # 最大尝试次数（30次，每次1秒）
    local attempt=1

    echo "Waiting for PostgreSQL to start..."

    while [ $attempt -le $max_attempts ]; do
        pg_isready -h localhost -U $POSTGRES_USER >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            log "PostgreSQL is running and accepting connections"
            return 0
        fi

        log "Attempt $attempt/$max_attempts: PostgreSQL is not ready yet..."
        sleep 1
        attempt=$((attempt + 1))
    done

    log "ERROR: PostgreSQL did not start within 30 seconds"
    exit 1
}

main() {
    # Pre-backup hook
    if [ -d "${HOOKS_DIR}" ]; then
      run-parts -a "pre-backup" --exit-on-error "${HOOKS_DIR}"
    fi

    #Initialize dirs
    mkdir -p "$BACKUP_DIR"/{full,incremental,manifest}

    check_postgres_running

    # 检查是否需要完整备份（每周日或首次运行）
    if [ "$TODAY" -eq 7 ] || [ ! -d "$BACKUP_DIR/full" ]; then
        full_backup
        verify_backup "$BACKUP_DIR/full/${DB_NAME}-full-${TIMESTAMP}" "full"
    else
        incremental_backup
        verify_backup "$BACKUP_DIR/incremental/${DB_NAME}-incremental-${TIMESTAMP}" "incremental"
    fi

    # Post-backup hook
    if [ -d "${HOOKS_DIR}" ]; then
      run-parts -a "post-backup" --reverse --exit-on-error "${HOOKS_DIR}"
    fi
}


# 执行主逻辑
main
