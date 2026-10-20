#lang racket

;;; edit-tui-rebuild/command/api.rkt —— 命令表 API

(require "table.rkt"
         "key.rkt")

(provide
 ;; 单表
 command-table?
 command-table-empty
 command-table-add
 command-table-from-bindings
 command-table-bindings
 command-table-merge
 command-table-lookup
 command-table-exact?
 command-table-prefix?

 ;; stack
 command-table-stack?
 command-table-stack-empty
 command-table-stack-from-tables
 command-table-stack-tables
 command-table-stack-over
 command-table-stack-push
 command-table-stack-pop
 command-table-stack-remove
 command-table-stack-lookup

 ;; 构造 DSL
 keys

 ;; key token = 标签 + 原始字节
 (struct-out key-token)
 mods-order normalize-mods
 key key? key-tag key-bytes key=? key->string key-text
 raw-key-token)
