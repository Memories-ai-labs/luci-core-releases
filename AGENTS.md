# AGENTS.md

公开仓库，只放两样东西：`install.sh` 和 GitHub Releases 里的安装产物
（`luci-core-linux-<arch>.tar.gz`、`ocr-zh-v1.tar.gz`、`SHA256SUMS`）。
源码在私有仓库 `Memories-ai-labs/luci-core`（本机 `~/dev2/luci-core`）。

一行安装靠的就是这里：
`curl -fsSL https://raw.githubusercontent.com/Memories-ai-labs/luci-core-releases/main/install.sh | sh`。
`releases/latest/download/` 只看得见已发布的 Release，所以这里的 Release 是发布状态，不是 draft。

## 硬规则

1. **`install.sh` 不在这里改。** 它是 `luci-core/scripts/install.sh` 的逐字节副本，tarball 里还内嵌一份做自修复。
   改去私有仓库，过门槛、等 CI 绿，再用 `luci-core/scripts/promote-release.sh` 带过来。手改会和 tarball 里那份对不上。
2. **Release 只通过 `promote-release.sh` 建。** 它从私有仓库的 draft 或 CI run 取产物、校验 `SHA256SUMS`、
   核对 tarball 里的 `install.sh` 和版本号，再在这里发布。不手工 `gh release create`，不手工传产物。
3. **发布（publish）是用户的决定。** 用户没说就加 `--draft`。
4. **动 remote 前 `gh auth status`**，active 必须是 `OpenInterYRZ`。
5. 没有 LICENSE，等用户定；不要自己加。README 不提许可。
6. 这里不存 `SHA256SUMS`，它只在 Release 里。

## 文件

| 文件 | 内容 |
|---|---|
| `README.md` | 给只看得到这个仓库的人：是什么、要求、一行安装、接 Grok Bot / Muse / OpenClaw、选项、校验、卸载 |
| `install.sh` | 安装脚本副本（见规则 1） |

发版流程和历史在私有仓库 `luci-core/docs/releasing.md`。
