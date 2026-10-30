# ghcn

**在 `github.com` 无法访问的环境里,把 GitHub 重新用起来。**

不需要 Homebrew,不需要 sudo,不需要 Xcode Command Line Tools,也不需要翻墙。

```
api.github.com  ✅ 通       →  认证、API 调用、推送、建仓库 全部可用
github.com      ❌ 不通     →  网页、git 原生 push、gh browse 不可用
```

本仓库把这条缝里能做的事固化成一套可直接复用的工具:`gh` 安装器、`git` 安装器、
PAT 认证脚本,以及一个 **用 GitHub API 代替 `git push`** 的推送器。

---

## 一、它解决什么

三件通常被当作"必须"的事,在这里都不成立:

| 通常做法 | 这里的现实 |
|---|---|
| `brew install gh git` | 没有 Homebrew;装 brew 本身就要 sudo 建 `/opt/homebrew` |
| `xcode-select --install` | 需要 GUI 确认 + 约 2GB 下载 |
| 系统自带 `git` | `/usr/bin/git` 只是 **118 KB 的空壳 shim**,一执行就弹安装对话框 |
| `gh auth login` 设备码登录 | 授权页在 `github.com/login/device`,**打不开** |
| `git push` | 走 `github.com:443`,**TLS 被 SNI 阻断** |

## 二、实测的网络现实

2026-10-30,中国大陆家宽(无代理),实测结果:

| 主机 | 结果 | 说明 |
|---|---|---|
| `api.github.com` | ✅ 通,~0.6s | 认证、REST API、Git Data API 全靠它 |
| `release-assets.githubusercontent.com` | ✅ 通 | 能下载任意 GitHub Release 资产 |
| `codeload.github.com` | ✅ 通 | 能下载仓库源码包 |
| `github.com` | ❌ TLS 被重置 | 换 4 个 IP、换 IPv6 都一样;TCP 能连上,TLS 立刻被断,典型 SNI 阻断 |
| `gist.github.com` / `raw.githubusercontent.com` | ❌ 不通 | |
| `gitee.com/mirrors/*` | ⚠️ 401 | 需登录,不能匿名 clone |

**关键洞察**:阻断的是 `github.com` 这个 SNI,不是 GitHub 整个网络。
`api.github.com` 是另一台主机、另一张证书,它通 —— 而 GitHub 的 REST API **能力上覆盖了
网页能做的绝大部分事**:建仓库、提交文件、开 PR、发 issue、改分支。

## 三、快速开始

```bash
git clone <本仓库>   # 或直接下载 ZIP
cd ghcn
./install.sh                 # 装 gh(从 api.github.com 下载 + sha256 校验)
./install-git.sh --cn        # 装 git(conda-forge,自带依赖;--cn 用 TUNA 镜像)
./tools/set-token.sh         # 用 PAT 登录(见下节)
./bin/ghcn                   # 自检:网络/工具/认证/git 配置
```

三步之后:

```bash
./bin/gh api /user           # 已认证的身份
./bin/git --version          # git 2.56.0
git push-api --dry-run       # API 推送就绪
```

## 四、认证:为什么必须用 PAT

`gh auth login` 的设备流要求你打开 `github.com/login/device` 输入一次性码 ——
而那台主机不通,所以这条路在受限网络下**必然失败**。

正确做法是在**能访问 GitHub 的设备上**(手机流量通常可以)生成 Personal Access Token:

1. 打开 `https://github.com/settings/tokens`
2. `Generate new token (classic)`
3. 勾选 `repo`、`read:org`、`gist`(需要改 CI 再加 `workflow`)
4. 复制 `ghp_...`,然后:

```bash
printf '%s' 'ghp_xxxxx' | ./tools/set-token.sh
```

token 校验走 `api.github.com`,所以**生成端能上网即可,使用端不通也没关系**。

> 安全提示:token 明文出现在命令行/聊天记录里就视为已泄露,建议设较短有效期,
> 用完去 token 页面 Revoke。本工具把它存在 `.gh-config/`(700),不入库。

## 五、三个工具

### `bin/gh` —— GitHub CLI

带认证配置与 PATH 的包装器。任何目录用绝对路径都能跑。

```bash
./bin/gh api /repos/owner/repo
./bin/gh pr list -R owner/repo
./bin/gh issue create -R owner/repo -t "标题" -b "正文"
./bin/gh repo list
```

### `bin/git` —— 真 git

conda-forge 的 git 2.56.0,装在 `.gitenv/`,自带 openssl / libcurl / pcre2 等全部依赖。
全局配置放在仓库内 `.gitconfig`,不污染 `~/.gitconfig`。

`install-git.sh --cn` 会加上镜像改写:

```ini
[url "https://gitclone.com/github.com/"]
    insteadOf = https://github.com/
```

于是 `git clone https://github.com/owner/repo` 这种**标准写法**会自动走镜像。
副作用是 `git remote -v` 里显示镜像地址;镜像内容可用 commit SHA 与 `gh api` 交叉校验
(内容寻址,篡改必然导致 SHA 不一致)。

镜像不保证每个仓库都有缓存,失败(如 502)时可用 `codeload` 源码包回退:

```bash
curl -sSL -o r.tar.gz https://codeload.github.com/owner/repo/tar.gz/refs/heads/main
mkdir r && tar xzf r.tar.gz -C r --strip-components=1
```

### `git push-api` —— 用 API 代替 `git push`(本仓库的核心)

```bash
git push-api                          # 推当前分支到 origin
git push-api --dry-run                # 只看计划,不动远端
git push-api --prune                  # 删除远端多余文件(镜像本地)
git push-api -b dev --from main       # 新建分支,以 main 为基线
git push-api -m "feat: xxx"           # 覆盖提交信息
git push-api -R owner/repo            # 覆盖仓库
```

**原理**:git 的 blob/tree/commit 与 GitHub 的 Git Data API 都是**内容寻址**,
同一份内容算出的 SHA-1 完全相同。因此:

1. 只上传本地与远端内容不同的文件,相同的直接引用远端已有 blob(零上传)
2. 用 `base_tree` 在远端 tree 上增量修改,未变文件不必重建条目
3. 在远端分支 tip 上创建 commit,再把 ref 前移

实测(真仓库,非模拟):

| 场景 | 结果 |
|---|---|
| 首次推 5 个文件 | 上传 5 个 blob,`base_tree` 保留远端已有的 README |
| 无差异推送 | 判定"无需推送",**0 次写请求** |
| 改 1 个 + 新增 1 个(内容与已有 blob 相同) | 上传 1 / **复用 1** |
| `--prune` | 精确删除远端独有文件 |
| 可执行位 `100755` | 保留 |
| 子目录 | 正确建为 tree 对象 |
| 新分支 `--from main` | 父提交正确指向 main tip |
| **推送到空仓库** | 自动用 Contents API 引导首个提交,最终仍只留 1 个根提交 |
| blob 完整性 | 上传后校验 API 返回 sha == 本地 sha,不一致直接报错 |

**代价(必须知道)**:

- 远端 commit 的 **sha 与本地不同**(相当于把树 replay 到远端 tip,类似 rebase/squash)
- 本地提交历史**不会**同步,每次推送合成一个 commit
- 受 GitHub API 速率限制(5000 次/小时);单文件 100MB 上限
- submodule 会被跳过
- 空仓库无法直接建 blob(API 返回 409),需先用 Contents API 造一个提交;
  本工具已自动处理,并把临时提交替换成你自己的根提交

## 六、目录结构

```
install.sh                 安装 gh(api 资产端点 + sha256 校验)
install-git.sh             安装 git(conda-forge 独立环境)
LICENSE
README.md
bin/
  gh                        gh 包装器(认证 + PATH)
  git                       git 包装器(环境 + 配置)
  git-push-api              push-api 入口(git 子命令)
  ghcn                      自检 doctor
tools/
  set-token.sh             PAT 登录
  api-push/
    git-push-api.py        推送实现(单文件,仅标准库)
```

运行时产物(已在 `.gitignore` 中排除):

```
bin/gh.bin        gh 二进制
.gitenv/          git 环境(~226MB)
.mamba/           conda 包缓存(装完可删)
.gh-config/       认证凭据(700,含 token,切勿提交)
.gitconfig        本仓库的 git 全局配置
```

## 七、已验证环境

| 项 | 值 |
|---|---|
| 系统 | macOS 26.6.2 (arm64) |
| 网络 | 中国大陆家宽,无代理 |
| gh | 2.103.3 |
| git | 2.56.0 (conda-forge) |
| micromamba | 2.10.0 |
| Python(用于 push-api) | 3.12,仅标准库 |

也支持 Linux(amd64 / arm64),安装脚本按平台自动选资产,但**未实测**。

## 八、为什么不干脆用代理

代理当然更彻底。本项目的定位是**没有代理可用时**的兜底方案,以及理解
"GitHub 的哪些能力其实不依赖 `github.com`"。两者不冲突:有代理时用原生
`git push` 更省事;没有代理时,这套工具能让日常工作继续。

## License

MIT
