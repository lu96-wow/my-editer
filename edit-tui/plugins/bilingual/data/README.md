# bilingual translation data

`racket-zh.rktd` 由外部构建项目生成，不是手写文件。

来源：

```text
/home/lu96/work/racket-translate-lang-build/dist/racket-cn/tables/*.rktd
```

格式（两行 Racket 数据）：

1. `CN symbol -> EN symbol`
2. `CN keyword -> EN keyword`

插件运行时把它反转成：

- `EN symbol -> CN symbol`
- `EN keyword -> CN keyword`

## 更新

在 repo 根目录运行：

```bash
racket edit-tui/plugins/bilingual/scripts/import-tables.rkt \
  --from /home/lu96/work/racket-translate-lang-build/dist/racket-cn/tables
```

默认输出：

```text
edit-tui/plugins/bilingual/data/racket-zh.rktd
```

不要直接手改 `racket-zh.rktd`；更新外部 maps 后重新运行 import。
