#!/usr/bin/env bash
# ============================================================
# publish.sh
# 逐包发布 core + service，跳过已存在版本，发布后打 tag
# 内置 npm 频率限制重试逻辑
# 支持 DRY_RUN=true 模式进行空跑测试
# ============================================================

set -euo pipefail

DRY_RUN="${DRY_RUN:-false}"
MAX_RETRIES=3
RETRY_DELAY=30         # 被限流时等待秒数
PUBLISH_DELAY=8        # 每个包之间的间隔秒数（避免触发限流）
FAILED_PACKAGES=()
SKIPPED_PACKAGES=()
PUBLISHED_PACKAGES=()

# ---- helpers ------------------------------------------------
log()  { echo "[publish] $*"; }
warn() { echo "[publish][WARN] $*" >&2; }
err()  { echo "[publish][ERROR] $*" >&2; }

is_dry_run() { [ "$DRY_RUN" = "true" ]; }

# 检查 npm registry 上是否已存在某版本
version_exists() {
  local pkg_name="$1"
  local pkg_version="$2"
  if npm view "${pkg_name}@${pkg_version}" version > /dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

# 带重试的 publish
publish_with_retry() {
  local pkg_dir="$1"
  local pkg_name="$2"
  local pkg_version="$3"
  local attempt=0
  local current_delay=$RETRY_DELAY

  # dry-run 模式：使用 npm publish --dry-run 仅模拟
  local publish_cmd="npm publish --access public"
  if is_dry_run; then
    publish_cmd="npm publish --access public --dry-run"
  fi

  while [ $attempt -lt $MAX_RETRIES ]; do
    attempt=$((attempt + 1))
    log "Publishing ${pkg_name}@${pkg_version} (attempt ${attempt}/${MAX_RETRIES})$(is_dry_run && echo ' [DRY-RUN]')..."

    set +e
    output=$(cd "$pkg_dir" && $publish_cmd 2>&1)
    exit_code=$?
    set -e

    if [ $exit_code -eq 0 ]; then
      log "Published ${pkg_name}@${pkg_version}$(is_dry_run && echo ' [DRY-RUN]')"
      return 0
    fi

    # 检查是否是频率限制（429 Too Many Requests）
    if echo "$output" | grep -qiE "429|too many requests|rate limit|ETOOMANYREQUEST"; then
      warn "Hit npm rate limit for ${pkg_name}. Waiting ${current_delay}s before retry..."
      sleep $current_delay
      current_delay=$((current_delay * 2))
      continue
    fi

    # 检查是否是 "已存在" 的误报
    if echo "$output" | grep -qiE "cannot publish over the previously published|EPUBLISHCONFLICT|You cannot publish over"; then
      warn "${pkg_name}@${pkg_version} already exists on npm (detected during publish). Skipping."
      SKIPPED_PACKAGES+=("${pkg_name}@${pkg_version}")
      return 0
    fi

    # 其他错误
    err "Failed to publish ${pkg_name}@${pkg_version}: ${output}"
    if [ $attempt -lt $MAX_RETRIES ]; then
      log "Retrying in ${current_delay}s..."
      sleep $current_delay
    fi
  done

  return 1
}

# 发布后创建 git tag
create_tag() {
  local pkg_name="$1"
  local pkg_version="$2"
  local tag_name="${pkg_name}@${pkg_version}"

  if git rev-parse "refs/tags/${tag_name}" > /dev/null 2>&1; then
    log "Tag ${tag_name} already exists, skipping."
    return 0
  fi

  if is_dry_run; then
    log "[DRY-RUN] Would create tag: ${tag_name}"
    return 0
  fi

  log "Creating tag: ${tag_name}"
  git tag -a "${tag_name}" -m "Release ${tag_name}"
}

# ---- main ---------------------------------------------------

if is_dry_run; then
  log "============================================"
  log "  DRY-RUN MODE - no real publish or tags"
  log "============================================"
fi

# 仅在 CI 环境设置 git 身份（避免覆盖本地开发者配置）
if [ -n "${CI:-}" ]; then
  git config user.name "github-actions[bot]"
  git config user.email "github-actions[bot]@users.noreply.github.com"
fi

# 收集所有要发布的包目录
PACKAGE_DIRS=()

# 1) core 包（优先发布，因为 service 依赖 core）
if [ -d "packages/sdk-core" ]; then
  PACKAGE_DIRS+=("packages/sdk-core")
fi

# 2) service 下所有包
for dir in service/*/; do
  if [ -f "${dir}package.json" ]; then
    PACKAGE_DIRS+=("$dir")
  fi
done

log "Found ${#PACKAGE_DIRS[@]} packages to process."

# 逐包处理
for pkg_dir in "${PACKAGE_DIRS[@]}"; do
  # 去除末尾的 / 以确保路径一致
  pkg_dir="${pkg_dir%/}"

  pkg_name=$(node -p "require('./${pkg_dir}/package.json').name")
  pkg_version=$(node -p "require('./${pkg_dir}/package.json').version")

  # 前置检查: 版本是否已存在
  if version_exists "$pkg_name" "$pkg_version"; then
    log "Skip ${pkg_name}@${pkg_version} already exists on npm."
    SKIPPED_PACKAGES+=("${pkg_name}@${pkg_version}")
    continue
  fi

  # 检查 dist 目录是否存在（确保已编译）
  if [ ! -d "${pkg_dir}/dist" ]; then
    warn "${pkg_name} has no dist/ directory. Skipping."
    SKIPPED_PACKAGES+=("${pkg_name}@${pkg_version}")
    continue
  fi

  # 发布
  if publish_with_retry "$pkg_dir" "$pkg_name" "$pkg_version"; then
    PUBLISHED_PACKAGES+=("${pkg_name}@${pkg_version}")
    create_tag "$pkg_name" "$pkg_version"
  else
    FAILED_PACKAGES+=("${pkg_name}@${pkg_version}")
  fi

  # dry-run 模式跳过包间延迟
  if ! is_dry_run; then
    sleep $PUBLISH_DELAY
  fi
done

# 推送所有新创建的 tags
if [ ${#PUBLISHED_PACKAGES[@]} -gt 0 ]; then
  if is_dry_run; then
    log "[DRY-RUN] Would push ${#PUBLISHED_PACKAGES[@]} tags to remote"
  else
    log "Pushing tags to remote..."
    git push origin --tags
  fi
fi

# ---- 汇总报告 ------------------------------------------------
echo ""
log "========== Publish Summary$(is_dry_run && echo ' [DRY-RUN]') =========="
log "Published: ${#PUBLISHED_PACKAGES[@]}"
for p in "${PUBLISHED_PACKAGES[@]}"; do echo "  [ok] $p"; done

log "Skipped (already exists): ${#SKIPPED_PACKAGES[@]}"
for p in "${SKIPPED_PACKAGES[@]}"; do echo "  [skip] $p"; done

log "Failed: ${#FAILED_PACKAGES[@]}"
for p in "${FAILED_PACKAGES[@]}"; do echo "  [fail] $p"; done

if [ ${#FAILED_PACKAGES[@]} -gt 0 ]; then
  err "Some packages failed to publish!"
  exit 1
fi

log "All done!"
