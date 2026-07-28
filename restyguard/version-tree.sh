#!/bin/sh
# File: version-tree.sh
# Version: 1.3.3
# Description: Final perfect version. Corrected both grep and awk regex to
#              handle all discovered patterns, including versions in parentheses
#              like '(v1.2.3)'.

set -e

echo "Project Structure and File Versions:"
echo "------------------------------------"

find . -type f -not -path "./.git/*" | sort | while read -r filepath; do
    
    # 步骤 1: 修正 grep 表达式，更准确地匹配括号内的版本
    # `\((v|V)` 确保我们只匹配括号内以 v 或 V 开头的版本字符串
    version_line=$(grep -m1 -E 'Version:|\((v|V)' "$filepath" || true)

    if [ -n "$version_line" ]; then
        # 步骤 2: 修正 awk 表达式，移除行首锚点 `^`
        # 这样它就能匹配字段中任意位置的版本字符串，比如从 `(v1.0.0)` 中找到 `v1.0.0`
        version=$(echo "$version_line" | awk '{
            for (i=1; i<=NF; i++) {
                if ($i ~ /v?[0-9]+\.[0-9]+\.?[0-9]*/) {
                    print $i;
                    exit;
                }
            }
        }' | tr -d '()')

        if [ -n "$version" ]; then
            printf "%-50s %s\n" "$filepath" "$version"
        else
            printf "%-50s [Pattern Mismatch]\n" "$filepath"
        fi
    else
        printf "%-50s [No Version Comment]\n" "$filepath"
    fi
done

echo "------------------------------------"
