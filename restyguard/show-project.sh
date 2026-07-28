#!/bin/sh
# File: show-project.sh
# Version: v1.0.1
# Description: Displays the project file tree and then concatenates the
#              content of all text files. Excludes .git and .flyctl directories.

set -e

# --- 第一部分：显示项目文件树 ---
echo "======================================================================"
echo " Project File Tree"
echo "======================================================================"

# 使用 'tree' 命令（如果已安装）。-I 参数可以排除多个目录，用 | 分隔。
if command -v tree >/dev/null 2>&1; then
  tree -a -I ".git|.flyctl"
else
  # 如果没有 'tree'，则在 'find' 命令中添加排除规则。
  echo "INFO: 'tree' command not found. Using 'find' for basic listing."
  find . -not -path "./.git/*" -not -path "./.flyctl/*" | sed -e "s/[^-][^\/]*\// |/g" -e "s/|\([^ ]\)/|-- \1/"
fi
echo ""
echo ""


# --- 第二部分：显示每个文件的具体内容 ---
echo "======================================================================"
echo " File Contents"
echo "======================================================================"

# 【关键修正】在 find 命令中增加了 -not -path "./.flyctl/*" 来排除 .flyctl 目录。
find . -type f -not -path "./.git/*" -not -path "./.flyctl/*" -not -path "./certs/*" | sort | while read -r filepath; do
  
  # 检查并跳过二进制文件。
  case "$filepath" in
    *.png|*.jpg|*.jpeg|*.gif|*.ico|*.zip|*.gz|*.tar|*.bin|*.exe|*.so|*.o|*.a)
      continue
      ;;
    # 跳过脚本自身。
    *show-project.sh)
      continue
      ;;
  esac

  echo ""
  echo "----------------------------------------------------------------------"
  # 打印文件路径标题。
  printf "### File: %s\n" "$filepath"
  echo "----------------------------------------------------------------------"
  
  # 打印文件内容。
  cat "$filepath"
  
done

echo ""
echo "======================================================================"
echo " End of Project Overview"
echo "======================================================================"
