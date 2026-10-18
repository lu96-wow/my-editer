#lang racket

;;; env/command.rkt —— 命令注册表的“值”部分（复用旧 command 层的纯数据）
;;; layer  : env
;;; effect : 无（纯值）

;;; 命令 = command 结构（run / note / input），注册表是 environment.commands：
;;;
;;;     command-id : symbol
;;;     command    : command
;;;
;;; keymap 的叶子存 **command-id**，dispatch 再用 environment 查 command。
;;; 这样 keymap 不需要知道命令实现，命令也可以被插件覆盖 / 重绑定。
;;;
;;; 本模块不新造命令结构，直接复用 edit-tui/command/command.rkt。
;;; 但把它的 `input` 结构重命名成 `command-input-spec`，避免与 model/input.rkt
;;; 的根 `input`（运行期输入状态）撞名。
;;;
;;; 旧的 run 返回 (listof intent)，rebuild 的 command-run 改为返回 transition；
;;; 结构本身不限制返回类型，所以可以平滑复用。

(require (rename-in "../command/command.rkt"
                    [input       command-input-spec]
                    [input?      command-input-spec?]
                    [input-kind  command-input-spec-kind]
                    [input-prompt command-input-spec-prompt]
                    [input-init  command-input-spec-init]))

(provide (struct-out command)
         cmd
         ->command
         command-note-string
         command-needs-input?
         command-input-spec
         command-input-spec?
         command-input-spec-kind
         command-input-spec-prompt
         command-input-spec-init
         command-run/ctx
         command-note-text)

;; 用 ctx 调命令（ctx 的具体结构由 dispatch 块定义）。
(define (command-run/ctx c ctx)
  ((command-run c) ctx))

;; note 允许 thunk；解析成字符串（#f 保留）。
(define (command-note-text c)
  (define n (command-note c))
  (cond [(procedure? n) (n)]
        [else n]))
