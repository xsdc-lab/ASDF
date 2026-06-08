#!/bin/bash
#
# 备份 git 项目及其所有 submodule 为裸仓库
# 用法: ./backup-repo.sh [备份目标目录]
# 默认备份到: /opt/git-backups/
#

set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_NAME="$(basename "$REPO_DIR")"
BACKUP_DIR="${1:-/opt/git-backups/$REPO_NAME}"

# 确保从仓库根目录执行
if [ ! -f "$REPO_DIR/.gitmodules" ] && [ ! -d "$REPO_DIR/.git" ]; then
    echo "错误: 当前目录不是一个有效的 git 仓库"
    exit 1
fi

echo "=========================================="
echo "  Git 项目备份脚本"
echo "=========================================="
echo "源项目: $REPO_DIR"
echo "备份目录: $BACKUP_DIR"
echo "=========================================="

# 创建备份目录
mkdir -p "$BACKUP_DIR"

# 1. 备份主项目为裸仓库
echo ""
echo "[1/3] 备份主项目..."
MAIN_BACKUP="$BACKUP_DIR/${REPO_NAME}.git"
if [ -d "$MAIN_BACKUP" ]; then
    echo "  警告: 备份目录已存在，将覆盖: $MAIN_BACKUP"
    rm -rf "$MAIN_BACKUP"
fi

git clone --bare "$REPO_DIR" "$MAIN_BACKUP"
echo "  ✓ 主项目已备份到: $MAIN_BACKUP"

# 2. 备份所有 submodule
echo ""
echo "[2/3] 备份 submodules..."
SUBMODULE_BACKUP_DIR="$BACKUP_DIR/submodules"
mkdir -p "$SUBMODULE_BACKUP_DIR"

cd "$REPO_DIR"
submodule_count=0

if [ -f ".gitmodules" ]; then
    # 提取所有 submodule 名称
    while IFS= read -r subsection; do
        submodule_name="$subsection"
        submodule_path=$(git config --file .gitmodules --get "submodule.${submodule_name}.path")
        submodule_url=$(git config --file .gitmodules --get "submodule.${submodule_name}.url")
        
        # 检查 submodule 是否存在且已初始化
        # .git 可能是目录或指向 gitdir 的文本文件
        if [ -d "$REPO_DIR/$submodule_path" ] && [ -e "$REPO_DIR/$submodule_path/.git" ]; then
            # 从 URL 生成备份文件名
            backup_name=$(basename "$submodule_url" | sed 's/.git$//')
            
            echo "  备份: ${submodule_name} (${backup_name})"
            
            submodule_backup="$SUBMODULE_BACKUP_DIR/${backup_name}.git"
            if [ -d "$submodule_backup" ]; then
                rm -rf "$submodule_backup"
            fi
            
            git clone --bare "$REPO_DIR/$submodule_path" "$submodule_backup"
            echo "    ✓ 已备份到: $submodule_backup"
            submodule_count=$((submodule_count + 1))
        else
            echo "  跳过 (未初始化): ${submodule_name} (${submodule_path})"
        fi
    done < <(git config --file .gitmodules --get-regexp path | sed 's/\.[^.]*$//' | sed 's/submodule\.//' | sort -u)
else
    echo "  没有找到 .gitmodules 文件"
fi

echo "  共备份 $submodule_count 个 submodule"

# 3. 生成说明文件和辅助脚本
echo ""
echo "[3/3] 生成说明文件..."

cat > "$BACKUP_DIR/README.md" << EOF
# ${REPO_NAME} Git 备份

备份时间: $(date '+%Y-%m-%d %H:%M:%S')
备份来源: $REPO_DIR

## 目录结构

\`\`\`
${BACKUP_DIR}/
├── ${REPO_NAME}.git/          ← 主项目裸仓库
├── submodules/                ← submodule 裸仓库
│   ├── *.git/
│   └── ...
├── README.md                  ← 本文件
└── restore-local.sh           ← 本地恢复辅助脚本
\`\`\`

## Clone 主项目

### 本地 clone
\`\`\`bash
git clone ${MAIN_BACKUP}
cd ${REPO_NAME}
git submodule update --init --recursive
\`\`\`

### 通过网络 clone (SSH)
\`\`\`bash
git clone user@$(hostname):${MAIN_BACKUP}
cd ${REPO_NAME}
git submodule update --init --recursive
\`\`\`

## 完全离线使用 (本地 submodule)

如果需要完全离线环境，可以使用本地 submodule 备份替换远程 URL：

\`\`\`bash
git clone ${MAIN_BACKUP}
cd ${REPO_NAME}
# 运行恢复脚本（会在项目根目录执行）
bash \${BACKUP_DIR}/restore-local.sh
git submodule sync
git submodule update --init --recursive
\`\`\`

## Submodule 列表

| Submodule | 原始 URL | 本地备份 |
|-----------|----------|----------|
EOF

# 添加 submodule 列表到 README
cd "$REPO_DIR"
if [ -f ".gitmodules" ]; then
    while IFS= read -r subsection; do
        submodule_name="$subsection"
        submodule_path=$(git config --file .gitmodules --get "submodule.${submodule_name}.path")
        submodule_url=$(git config --file .gitmodules --get "submodule.${submodule_name}.url")
        backup_name=$(basename "$submodule_url" | sed 's/.git$//')
        echo "| \`$submodule_path\` | $submodule_url | \`submodules/${backup_name}.git\` |" >> "$BACKUP_DIR/README.md"
    done < <(git config --file .gitmodules --get-regexp path | sed 's/\.[^.]*$//' | sed 's/submodule\.//' | sort -u)
fi

# 创建本地恢复脚本
cat > "$BACKUP_DIR/restore-local.sh" << RESTORE_EOF
#!/bin/bash
#
# 将 .gitmodules 中的 submodule URL 替换为本地备份路径
# 用法: cd <clone的项目目录> && bash /path/to/restore-local.sh
#

set -e

SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
SUBMODULE_DIR="\$SCRIPT_DIR/submodules"
BACKUP_DIR="\$SCRIPT_DIR"

if [ ! -f ".gitmodules" ]; then
    echo "错误: 当前目录没有 .gitmodules 文件"
    echo "请先在项目根目录运行此脚本"
    exit 1
fi

echo "将 submodule URL 替换为本地备份路径..."
echo ""

# 创建一个关联数组来映射路径到备份
declare -A path_to_backup

for backup in "\$SUBMODULE_DIR"/*.git; do
    [ -d "\$backup" ] || continue
    backup_name=\$(basename "\$backup" .git)
    path_to_backup[\$backup_name]="\$backup"
done

# 读取 .gitmodules 中的 submodule
modified=0
while IFS= read -r subsection; do
    submodule_name="\$subsection"
    submodule_path=\$(git config --file .gitmodules --get "submodule.\${submodule_name}.path" 2>/dev/null || true)
    submodule_url=\$(git config --file .gitmodules --get "submodule.\${submodule_name}.url" 2>/dev/null || true)
    
    [ -z "\$submodule_url" ] && continue
    
    # 从 URL 提取名称
    url_name=\$(basename "\$submodule_url" | sed 's/.git$//')
    local_backup="\${path_to_backup[\$url_name]}"
    
    if [ -n "\$local_backup" ] && [ -d "\$local_backup" ]; then
        echo "  替换: \$submodule_path"
        echo "    原 URL: \$submodule_url"
        echo "    新 URL: \$local_backup"
        git config --file .gitmodules --set "submodule.\${submodule_name}.url" "\$local_backup"
        modified=1
    else
        echo "  保留: \$submodule_path (未找到本地备份)"
    fi
done < <(git config --file .gitmodules --get-regexp path 2>/dev/null | sed 's/\.[^.]*\$//' | sed 's/submodule\.//' | sort -u)

if [ \$modified -eq 1 ]; then
    echo ""
    echo "✓ 已修改 .gitmodules，请继续执行:"
    echo "  git submodule sync"
    echo "  git submodule update --init --recursive"
else
    echo ""
    echo "未进行修改"
fi
RESTORE_EOF

chmod +x "$BACKUP_DIR/restore-local.sh"

echo ""
echo "=========================================="
echo "  ✓ 备份完成!"
echo "=========================================="
echo "备份位置: $BACKUP_DIR"
echo ""
echo "主项目:     $MAIN_BACKUP"
echo "Submodules: $SUBMODULE_BACKUP_DIR/"
echo "说明文件:   $BACKUP_DIR/README.md"
echo "=========================================="
echo ""
echo "其他人可以这样 clone:"
echo "  git clone $MAIN_BACKUP"
echo ""
echo "通过网络 (SSH):"
echo "  git clone user@$(hostname):$MAIN_BACKUP"