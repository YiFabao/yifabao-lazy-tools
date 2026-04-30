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

**使用示例：**
1. 在 visual 模式下选中包含 IP 地址的文本
2. 按 `<leader>ip`
3. 选区将被格式化的 IP 列表替换

### 📚 知识库管理 (`knowledge.lua`)

基于 SQLite + FTS5 的本地知识库系统，支持全文搜索。

**核心功能：**
- ✅ 保存视觉选区或剪贴板内容
- ✅ 全文搜索（支持中文 trigram 分词）
- ✅ 标签系统（自动检测 + 手动添加）
- ✅ 类型自动识别（IP/SQL/Code/URL/Markdown/Text）
- ✅ 版本历史与回滚
- ✅ 批量导出/导入（JSON/JSONL/Markdown）
- ✅ 统计分析（按类型/标签分布）
- ✅ Telescope 集成（实时搜索预览）

**默认键映射：**
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
| `<leader>im` | JSONL 迁移 |
| `<leader>ir` | 重建 FTS 索引 |

**Telescope 操作：**
| 快捷键 | 功能 |
|--------|------|
| `<CR>` | 插入选中的内容 |
| `dd` | 删除当前条目 |
| `<C-e>` / `ee` | 编辑当前条目 |

**命令支持：**
```vim
:KnowledgeList          " 打开知识库搜索
:KnowledgeStats         " 显示统计信息
:KnowledgeExport [fmt]  " 导出 (json/jsonl/markdown)
:KnowledgeImport <file> " 从文件导入
:KnowledgeRebuildFTS    " 重建 FTS 索引
```

## 安装

使用 [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  dir = "/path/to/yifabao-lazy-tools",
  config = function()
    require("edit_tools").setup({
      -- 可选配置
      ip = {
        keymap = "<leader>ip",           -- 自定义 IP 提取快捷键
        enable_legacy_keymap = true,     -- 启用 <leader>ic 快捷键
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

## 配置说明

### IP 工具配置

```lua
ip = {
  keymap = "<leader>ip",           -- 主快捷键
  enable_legacy_keymap = true,     -- 是否启用 <leader>ic (仅 CIDR)
}
```

### 知识库配置

```lua
knowledge = {
  keymaps = {
    -- 自定义所有快捷键
    knowledge_search = "<leader>ik",
    statistics = "<leader>ist",
    -- ... 其他键映射
  },
}
```

## 数据存储

知识库数据存储在 Neovim 的数据目录中：
- **数据库**: `~/.local/share/nvim/edit-tools/knowledge.db`
- **历史表**: `knowledge_history`（版本历史）
- **主表**: `knowledge`（当前条目）
- **全文索引**: `knowledge_fts`（FTS5 trigram 索引）

## 高级用法

### 标签搜索
在 Telescope 搜索框中使用 `tag:neovim` 来搜索特定标签：
```
tag:neovim vim configuration
```

### 版本回滚
1. 按 `<leader>ih` 输入知识 ID
2. 在历史列表中选择版本
3. 按 `<C-r>` 回滚到该版本

### 数据备份
```bash
# 导出为 JSON
:KnowledgeExport json

# 导出为 JSONL（兼容旧版本）
:KnowledgeExport jsonl

# 导出为可读文档
:KnowledgeExport markdown
```

### 性能优化

知识库内置了缓存机制：
- 类型检测缓存（最多 500 条）
- 标签检测缓存（最多 500 条）
- LRU 淘汰策略

## 贡献

欢迎提交 Issue 和 Pull Request！

## 许可证

MIT
