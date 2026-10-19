#lang racket

;;; edit-tui-rebuild/api/command.rkt —— 命令表 API

(require "../command/table.rkt")

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
 command-table-stack-push
 command-table-stack-pop
 command-table-stack-remove
 command-table-stack-lookup

 ;; 构造 DSL
 keys)
