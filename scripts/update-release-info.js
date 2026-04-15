#!/usr/bin/env node
// ============================================================
// update-release-info.js
// 更新 .release_info 文件：
//   - release_uuid:      重新生成 UUID v4
//   - integration_branch: 当前 git 分支名
//   - generated_at:       当前时间（ISO 8601 + 时区偏移）
//
// 用法:
//   node scripts/update-release-info.js
// ============================================================

const { execSync } = require("child_process");
const { randomUUID } = require("crypto");
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const RELEASE_INFO_PATH = path.join(ROOT, ".release_info");

// ---- helpers ------------------------------------------------

/**
 * 获取当前 git 分支名
 */
function getCurrentBranch() {
  try {
    return execSync("git rev-parse --abbrev-ref HEAD", {
      cwd: ROOT,
      stdio: "pipe",
    })
      .toString()
      .trim();
  } catch (e) {
    console.error(
      "[update-release-info] Failed to get current branch:",
      e.message,
    );
    process.exit(1);
  }
}

/**
 * 生成 ISO 8601 格式的当前时间（带时区偏移，如 2026-01-27T19:30:00+08:00）
 */
function getNowISO() {
  const now = new Date();
  const offsetMin = -now.getTimezoneOffset();
  const sign = offsetMin >= 0 ? "+" : "-";
  const absOffset = Math.abs(offsetMin);
  const hh = String(Math.floor(absOffset / 60)).padStart(2, "0");
  const mm = String(absOffset % 60).padStart(2, "0");

  const pad = (n) => String(n).padStart(2, "0");

  return (
    `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}` +
    `T${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}` +
    `${sign}${hh}:${mm}`
  );
}

// ---- main ---------------------------------------------------

function main() {
  const releaseInfo = {
    release_uuid: randomUUID(),
    integration_branch: getCurrentBranch(),
    generated_at: getNowISO(),
  };

  const content = JSON.stringify(releaseInfo, null, 4);

  fs.writeFileSync(RELEASE_INFO_PATH, content, "utf-8");

  console.log("[update-release-info] Updated .release_info:");
  console.log(content);
}

main();
