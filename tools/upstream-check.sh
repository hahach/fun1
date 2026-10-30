#!/usr/bin/env bash
# 同步前门禁：核对收编文件与清单的一致性（见 UPSTREAM.md §同步流程）。
# 跑 sha256sum -c，把每个失败项（哈希不符/文件缺失）与 UPSTREAM.md 差异表的
# 声明面对账：全部落在声明面内 → 通过；任何未声明漂移 → 非零退出，先处置再覆盖。
set -euo pipefail
cd "$(dirname "$0")/.."

# 差异表（「## 与上游的差异」到下一节之间）里反引号包裹的路径 = 允许漂移的声明面。
declared=$(awk '/^## 与上游的差异/{found=1; next} /^## /{found=0} found' UPSTREAM.md \
    | grep -o '`[^`]*`' | tr -d '`' | sort -u)

is_declared() {
    local path=$1 entry
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        # 精确匹配，或目录级声明（token 以 / 结尾）覆盖其下文件。
        if [ "$entry" = "$path" ]; then return 0; fi
        case "$entry" in
        */) [ "${path#"$entry"}" != "$path" ] && return 0 ;;
        esac
    done < <(printf '%s\n' "$declared")
    return 1
}

status=0
# 失败行形如「路径: FAILED」「路径: FAILED open or read」；
# 缺文件另出 stderr「sha256sum: 路径: No such file or directory」，与 FAILED 行同路径，去重。
# LC_ALL=C：coreutils 会本地化「FAILED/No such file」字样，固定英文便于解析。
check_output=$(LC_ALL=C sha256sum -c UPSTREAM-FILES.sha256 2>&1 || true)
failed_paths=$(printf '%s\n' "$check_output" | grep -E 'FAILED|No such file or directory' \
    | sed -e 's/: FAILED.*//' -e 's/^sha256sum: //' -e 's/: No such file or directory//' | sort -u)
while IFS= read -r path; do
    [ -n "$path" ] || continue
    if is_declared "$path"; then
        echo "已声明差异: $path"
    else
        echo "未声明漂移: $path" >&2
        status=1
    fi
done < <(printf '%s\n' "$failed_paths")

if [ "$status" = 0 ]; then
    echo "清单核对通过：失败项均在差异表声明面内。"
fi
exit "$status"
