#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
git push-api —— 用 GitHub REST API 代替 git push,绕开被墙的 github.com。

原理:
  本地 git 的 blob/tree/commit 全是内容寻址(git hash)。GitHub 的 Git Data API
  里 blob 同样是内容寻址。因此:
    1. 只上传本地与远端内容不同的文件(按 git blob sha 比对),相同跳过的文件
       可直接用远端已有 blob 的 sha 引用。
    2. 用 base_tree 在远端 tree 上做增量修改(新增/修改/可选删除)。
    3. 在远端分支 tip 上创建一个新 commit,并把 ref 前移。

代价(必须知道):
  - 远端产生的是**新 commit 对象**,sha 与本地 HEAD 不同(类似 rebase/squash)。
  - 本地提交历史不会同步到远端,每次推送合成一个 commit。
  - 受 API 速率限制(5000 次/小时)与单文件 100MB 限制。

用法:
  git push-api                        # 推当前分支到 origin
  git push-api --dry-run              # 只看计划,不改远端
  git push-api -m "commit message"    # 覆盖提交信息
  git push-api --prune                # 同时删除远端多余文件(镜像本地状态)
  git push-api --branch dev           # 推到指定分支
  git push-api -R owner/repo          # 覆盖仓库
"""
import argparse
import base64
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

API = "https://api.github.com"
WS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

MAX_BLOB = 100 * 1024 * 1024  # GitHub 单文件上限
PARALLEL = 8


class ApiError(Exception):
    pass


class RepoEmpty(Exception):
    """仓库没有任何提交。Git Data API 的 blob/tree/commit 端点会返回 409。"""


# ---------------------------------------------------------------- git helpers

def git(*args, cwd=None):
    r = subprocess.run(["git", *args], cwd=cwd, capture_output=True)
    if r.returncode != 0:
        raise ApiError("git %s 失败: %s" % (" ".join(args), r.stderr.decode(errors="replace").strip()))
    return r.stdout


def repo_from_remote(cwd):
    r = subprocess.run(["git", "config", "--get", "remote.origin.url"],
                       cwd=cwd, capture_output=True)
    raw = r.stdout.decode().strip()
    if not raw:
        raise ApiError("当前仓库没有 origin 远端;用 -R owner/repo 指定")
    m = re.search(r"github\.com[:/]+([^/]+)/([^/]+?)(?:\.git)?/?$", raw)
    if not m:
        raise ApiError("无法从 %s 解析出 GitHub 仓库,用 -R owner/repo 指定" % raw)
    return "%s/%s" % (m.group(1), m.group(2))


def local_files(cwd):
    """返回 {path: (mode, sha)},跳过 submodule。"""
    out = git("ls-tree", "-r", "-z", "HEAD", cwd=cwd)
    files, skipped = {}, []
    for rec in out.split(b"\0"):
        if not rec:
            continue
        head, _, path = rec.partition(b"\t")
        parts = head.split()
        mode, typ, sha = parts[0].decode(), parts[1].decode(), parts[2].decode()
        p = path.decode("utf-8", errors="replace")
        if typ != "blob":
            skipped.append(p)
            continue
        files[p] = (mode, sha)
    return files, skipped


# ------------------------------------------------------------------ gh token

def get_token():
    for k in ("GH_TOKEN", "GITHUB_TOKEN"):
        if os.environ.get(k):
            return os.environ[k].strip()
    gh = os.path.join(WS, "bin", "gh")
    gh = gh if os.path.exists(gh) else "gh"
    r = subprocess.run([gh, "auth", "token"], capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        raise ApiError("拿不到 GitHub token,请先 gh auth login")
    return r.stdout.strip()


# ----------------------------------------------------------------------- api

def api(method, path, token, data=None, allow404=False):
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(API + path, data=body, method=method)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            raw = r.read()
            return (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        if e.code == 409 and "empty" in raw.lower():
            raise RepoEmpty()
        if e.code == 404 and allow404:
            return None
        try:
            msg = json.loads(raw).get("message", raw)
        except Exception:
            msg = raw
        hint = ""
        if e.code == 403 and "rate limit" in str(msg).lower():
            hint = "\n提示:触发 API 速率限制,等一小时或换 token。"
        if e.code == 422:
            hint = "\n提示:常见原因是分支保护、非快进推送(--force)或 ref 不存在。" + \
                   "\n      非快进推送可加 --force(会覆盖远端该分支)。"
        raise ApiError("API %s %s 失败: HTTP %d — %s%s" % (method, path, e.code, msg, hint))


# ---------------------------------------------------------------------- main

def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="git push-api",
        description="通过 GitHub REST API 推送本地提交(绕开被墙的 github.com)",
    )
    ap.add_argument("-R", "--repo", help="owner/repo,默认取 origin")
    ap.add_argument("-b", "--branch", help="远端分支,默认当前分支")
    ap.add_argument("-m", "--message", help="提交信息,默认用本地 HEAD 的信息")
    ap.add_argument("--prune", action="store_true", help="删除远端存在但本地没有的文件")
    ap.add_argument("--force", action="store_true", help="强制更新 ref(覆盖非快进)")
    ap.add_argument("--dry-run", action="store_true", help="只显示计划")
    ap.add_argument("--from", dest="from_branch",
                    help="分支不存在时,以该远端分支为基线创建(类似 git checkout -b)")
    args = ap.parse_args(argv)

    token = get_token()
    cwd = os.getcwd()

    repo = args.repo or repo_from_remote(cwd)
    try:
        head = git("rev-parse", "HEAD", cwd=cwd).decode().strip()
    except ApiError:
        raise ApiError("本地还没有任何提交,先 git commit")
    if args.branch:
        branch = args.branch
    else:
        branch = git("rev-parse", "--abbrev-ref", "HEAD", cwd=cwd).decode().strip()
        if branch == "HEAD":
            raise ApiError("当前处于 detached HEAD,请用 -b 指定分支")
    lfiles, skipped = local_files(cwd)
    if skipped:
        print("跳过 submodule: %s" % ", ".join(skipped))

    meta = git("log", "-1", "--format=%an%x00%ae%x00%aI%x00%cn%x00%ce%x00%cI",
               cwd=cwd).decode().strip().split("\0")
    aname, aemail, adate, cname, cemail, cdate = meta
    subject = git("log", "-1", "--format=%s", cwd=cwd).decode().strip()
    message = args.message or subject

    # ---- 远端现状
    empty_repo = False
    try:
        ref = api("GET", "/repos/%s/git/ref/heads/%s" % (repo, branch), token, allow404=True)
    except RepoEmpty:
        ref = None
        empty_repo = True
    target_exists = ref is not None      # 目标分支本身是否已存在(注意与 parent 不是一回事)
    parent = base_tree = None
    remote = {}
    if not ref and args.from_branch:
        # 新建分支:以 --from 分支的 tip 为基线,而不是凭空造一个孤儿分支
        fref = api("GET", "/repos/%s/git/ref/heads/%s" % (repo, args.from_branch),
                   token, allow404=True)
        if not fref:
            raise ApiError("--from 指定的分支 %s 不存在" % args.from_branch)
        ref = fref
        print("分支 %s 不存在,以 %s 为基线新建" % (branch, args.from_branch))
    if ref:
        parent = ref["object"]["sha"]
        commit = api("GET", "/repos/%s/git/commits/%s" % (repo, parent), token)
        base_tree = commit["tree"]["sha"]
        tree = api("GET", "/repos/%s/git/trees/%s?recursive=1" % (repo, base_tree), token)
        for e in tree.get("tree", []):
            if e["type"] == "blob":
                remote[e["path"]] = (str(e["mode"]), e["sha"])
        print("远端 %s 分支: %d 个文件 @ %s" % (branch, len(remote), parent[:10]))
    else:
        print("远端 %s 分支: 不存在,将新建(空父提交;需要基线请加 --from <branch>)" % branch)

    remote_shas = {sha for _, sha in remote.values()}

    uploads, updates, deletes = [], [], []
    for path, (mode, sha) in sorted(lfiles.items()):
        cur = remote.get(path)
        if cur == (mode, sha):
            continue
        if sha in remote_shas:
            updates.append((path, mode, sha))       # 内容已在远端某处,无需上传
        else:
            uploads.append((path, mode, sha))
    if args.prune:
        deletes = [p for p in remote if p not in lfiles]

    print("计划: 上传 %d 个 / 复用 %d 个 / 删除 %d 个 / 未变 %d 个"
          % (len(uploads), len(updates), len(deletes), len(lfiles) - len(uploads) - len(updates)))
    if not (uploads or updates or deletes):
        print("没有差异,无需推送。")
        return 0
    for p, _, _ in uploads:
        print("  + %s" % p)
    for p in deletes:
        print("  - %s" % p)

    if args.dry_run:
        print("\n[dry-run] 未改动远端。")
        return 0

    # ---- 空仓库需要先有提交,否则 blob/tree/commit 全部 409
    if empty_repo:
        prefer = ["README.md", "README", "readme.md", "README.rst"]
        seed = next((p for p in prefer if p in lfiles), sorted(lfiles)[0] if lfiles else None)
        if not seed:
            raise ApiError("仓库为空,且本地没有可推送的文件")
        print("空仓库: 先用 Contents API 创建首个提交(种子文件 %s)" % seed)
        api("PUT", "/repos/%s/contents/%s" % (repo, seed), token, {
            "message": "chore: bootstrap for Git Data API",
            "content": base64.b64encode(open(os.path.join(cwd, seed), "rb").read()).decode(),
        })
        target_exists = True   # 现在 ref 已存在,稍后需要用 force 移到根提交

    # ---- 上传变更的 blob(并发)
    def push_blob(item):
        path, mode, sha = item
        full = os.path.join(cwd, path)
        if not os.path.exists(full):
            raise ApiError("本地文件消失: %s" % path)
        data = open(full, "rb").read()
        if len(data) > MAX_BLOB:
            raise ApiError("文件超过 100MB 上限: %s" % path)
        res = api("POST", "/repos/%s/git/blobs" % repo, token,
                  {"content": base64.b64encode(data).decode(), "encoding": "base64"})
        if res["sha"] != sha:
            raise ApiError("blob sha 不一致(可能有换行符转换): %s 本地=%s 远端=%s"
                           % (path, sha, res["sha"]))
        return path

    done = 0
    with ThreadPoolExecutor(max_workers=PARALLEL) as ex:
        futures = {ex.submit(push_blob, it): it[0] for it in uploads}
        for f in futures:
            f.result()
            done += 1
            sys.stdout.write("\r已上传 %d/%d 个 blob" % (done, len(uploads)))
            sys.stdout.flush()
    if uploads:
        print()

    # ---- 建 tree
    entries = []
    for path, mode, sha in uploads + updates:
        entries.append({"path": path, "mode": mode, "type": "blob", "sha": sha})
    for path in deletes:
        entries.append({"path": path, "mode": "100644", "type": "blob", "sha": None})
    payload = {"tree": entries}
    if base_tree:
        payload["base_tree"] = base_tree
    new_tree = api("POST", "/repos/%s/git/trees" % repo, token, payload)

    # ---- 建 commit + 移动 ref
    cpayload = {
        "message": message,
        "tree": new_tree["sha"],
        "parents": [parent] if parent else [],
        "author": {"name": aname, "email": aemail, "date": adate},
        "committer": {"name": cname, "email": cemail, "date": cdate},
    }
    new_commit = api("POST", "/repos/%s/git/commits" % repo, token, cpayload)

    if target_exists:
        # empty_repo 时:bootstrap 提交是临时的,用 force 把 ref 移到我们的根提交,
        # 这样远端历史从干净的一个提交开始(bootstrap 对象自然变成不可达,会被回收)
        api("PATCH", "/repos/%s/git/refs/heads/%s" % (repo, branch), token,
            {"sha": new_commit["sha"], "force": bool(args.force) or empty_repo})
    else:
        api("POST", "/repos/%s/git/refs" % repo, token,
            {"ref": "refs/heads/%s" % branch, "sha": new_commit["sha"]})

    print("\n✅ 已推送 %s → %s" % (repo, branch))
    print("   远端 commit: %s" % new_commit["sha"])
    print("   本地 HEAD  : %s  (sha 必然不同,属预期)" % head)
    print("   浏览: https://github.com/%s/commit/%s" % (repo, new_commit["sha"]))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ApiError as e:
        print("错误: %s" % e, file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
