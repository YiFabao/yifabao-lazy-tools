# Edit Tools - Neovim 效率工具集

一个强大的 Neovim 插件集合，包含 IP 地址提取/格式化和知识库管理功能。

## 功能特性

### 📡 IP 工具 (`ip.lua`)

快速提取和格式化选区中的 IP 地址：

- ✅ 支持 CIDR 格式 (`192.168.1.0/24`)
- ✅ 支持单 IP 地址 (`192.168.1.1`)
- ✅ 自动排序（按 IP 数值大小）
- ✅ CIDR 前缀验证（0-32）
- ✅ IP 地址合法性验证（每段 0-255）
- ✅ 去重处理
- ✅ 完整的撤销支持

**默认键映射：**
- `<leader>ip` - 提取选区中的所有 IP（CIDR + 单IP）
- `<leader>ic` - 仅提取 CIDR IP（向后兼容）

### 📚 知识库管理 (`knowledge.lua`)

基于 SQLite + FTS5 的本地知识库系统，支持全文搜索。

#### 核心功能
- ✅ 保存视觉选区或剪贴板内容
- ✅ 全文搜索（支持中文 trigram 分词）
- ✅ 标签系统（自动检测 + 手动添加）
- ✅ 类型自动识别（IP/SQL/Code/URL/Markdown/Text）
- ✅ 版本历史与回滚
- ✅ 批量导出/导入（JSON/JSONL/Markdown）
- ✅ 统计分析（按类型/标签分布）
- ✅ Telescope 集成（实时搜索预览）
- ✅ ⭐ 收藏/星标重要条目
- ✅ 👁 使用频率统计
- 🔥 **高级搜索**：`tag:neovim type:code date:2024-01-01..2024-12-31 [starred]`
- 🔥 **批量操作**：多选添加标签/导出
- 🔥 **相关条目**：基于标签推荐相似内容
- 🔥 **标签浏览器**：查看所有标签 + 计数
- 🔥 **模板系统**：预定义模板快速保存
- 🔥 **自动备份**：定期备份 + 备份管理
- 🔥 **Markdown 高亮**：Treesitter 语法着色

#### 默认键映射
| 快捷键 | 功能 |
|--------|------|
| `<leader>is` | 保存视觉选区 |
| `<leader>iv` | 保存剪贴板内容 |
| `<leader>ip` | 打开粘贴窗口 |
| `<leader>ik` | 搜索知识库 |
| `<leader>ih` | 查看历史记录 |
| `<leader>ist` | 统计信息 |
| `<leader>ie` | 导出数据 |
| `<leader>ii` | 导入数据 |
| `<leader>it` | 标签浏览器 |
| `<leader>iw` | 使用模板保存 |
| `<leader>ib` | 自动备份 |
| `<leader>il` | 备份列表 |
| `<leader>im` | JSONL 迁移 |
| `<leader>ir` | 重建 FTS 索引 |

#### Telescope 操作（主搜索界面）
| 快捷键 | 功能 |
|--------|------|
| `<CR>` | 插入选中的内容 |
| `dd` | 删除当前条目 |
| `<C-e>` / `ee` | 编辑当前条目 |
| `<C-h>` | 查看历史版本 |
| `<C-s>` | 收藏/取消收藏 ⭐ |
| `<C-t>` | 批量添加标签（支持多选） |
| `<C-x>` | 批量导出选中条目 |
| `<C-r>` | 查找相关条目（基于标签） |

#### Telescope 操作（历史界面）
| 快捷键 | 功能 |
|--------|------|
| `<CR>` / `<C-r>` | 回滚到指定版本 |
| `<C-d>` | 对比当前与历史版本 |
| `<C-b>` / `<Esc>` | 返回主搜索界面 |

#### 命令支持
```vim
:KnowledgeList          " 打开知识库搜索
:KnowledgeStats         " 显示统计信息
:KnowledgeExport [fmt]  " 导出 (json/jsonl/markdown)
:KnowledgeImport <file> " 从文件导入
:KnowledgeRebuildFTS    " 重建 FTS 索引
:KnowledgeTags          " 标签浏览器
:KnowledgeBackup        " 自动备份
:KnowledgeBackups       " 备份列表
:KnowledgeTemplate      " 使用模板保存
```

## 安装

使用 [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  dir = "/path/to/yifabao-lazy-tools",
  dependencies = {
    "tami5/sqlite.lua",
    "nvim-telescope/telescope.nvim",
  },
  config = function()
    require("edit_tools").setup({
      -- 可选配置
      ip = {
        keymap = "<leader>ip",           -- 自定义 IP 提取快捷键
        enable_legacy_keymap = true,     -- 启用 <leader>ic (仅 CIDR)
      },
      knowledge = {
        keymaps = {
          save_visual = "<leader>is",
          save_clipboard = "<leader>iv",
          paste_window = "<leader>ip",
          knowledge_search = "<leader>ik",
          migrate = "<leader>im",
          rebuild_fts = "<leader>ir",
          history = "<leader>ih",
          statistics = "<leader>ist",
          export = "<leader>ie",
          import = "<leader>ii",
          tag_browser = "<leader>it",
          save_template = "<leader>iw",
          auto_backup = "<leader>ib",
          list_backups = "<leader>il",
        },
      },
    })
  end,
}
```

## 依赖

- [neovim](https://github.com/neovim/neovim) >= 0.8
- [sqlite.lua](https://github.com/tami5/sqlite.lua)
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)（知识库搜索）

## 高级用法

### 🔍 高级搜索语法

支持组合查询条件：

```
# 按标签搜索
tag:neovim vim configuration

# 按类型过滤
type:sql SELECT * FROM

# 按日期范围
date:2024-01-01..2024-12-31

# 只看收藏的条目
[starred] 或 [star]

# 组合使用
tag:neovim type:code date:2024-01-01..2024-12-31
```

### 📝 模板系统

保存时可选择预定义模板：

- **代码片段** - 适合保存代码示例
- **命令记录** - 保存命令及输出
- **配置记录** - 配置文件及说明
- **问题排查** - 问题描述及解决方案
- **笔记** - 通用笔记模板

使用 `<leader>iw` 调用模板保存。

### 🏷 标签管理

使用 `<leader>it` 打开标签浏览器：
- 查看所有标签及使用次数
- 点击标签快速搜索相关内容

### 📊 批量操作

在 Telescope 搜索界面：
1. 按 `Tab` 多选条目
2. 按 `<C-t>` 批量添加标签
3. 按 `<C-x>` 批量导出选中

### ⭐ 收藏系统

- 按 `<C-s>` 收藏/取消收藏
- 使用 `[starred]` 搜索只看收藏
- 收藏条目在列表中显示 ⭐ 图标

### 📁 备份管理

- `<leader>ib` - 立即备份
- `<leader>il` - 查看备份列表
- 自动保留最近 10 个备份
- 支持恢复/删除备份

### 🔗 相关条目

在搜索界面按 `<C-r>` 查找与当前条目共享标签的相关内容。

## 数据存储

知识库数据存储在 Neovim 的数据目录中：
- **数据库**: `~/.local/share/nvim/edit-tools/knowledge.db`
- **备份目录**: `~/.local/share/nvim/edit-tools/backups/`
- **历史表**: `knowledge_history`（版本历史）
- **主表**: `knowledge`（当前条目，含 starred/view_count 字段）
- **全文索引**: `knowledge_fts`（FTS5 trigram 索引）

## 性能优化

知识库内置了多项优化：
- 类型/标签检测缓存（LRU，最多 500 条）
- 分页加载（limit 200）
- 增量索引重建（trigger 自动更新）
- 数据库连接池（复用连接）

## 贡献

欢迎提交 Issue 和 Pull Request！

## 许可证

MIT
