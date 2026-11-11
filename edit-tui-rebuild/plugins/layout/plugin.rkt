#lang racket

;;; edit-tui-rebuild/plugins/layout/plugin.rkt —— 布局命令插件
;;;
;;; 插件通过 commands 贡献 key -> command。命令是普通过程：
;;;   (ed state -> (values state' actions))
;;;
;;; host 只负责合并 command-table 并解释返回值；不需要知道 split/focus 的实现。

(require "../../core/command/api.rkt"
         "../../editor/api.rkt")

(provide layout-plugin)

(define (split-command dir)
  (λ (ed state) (editor-split! ed state dir)))

(define (focus-command dir)
  (λ (ed state) (editor-focus! ed state dir)))

(define (close-command ed state)
  (editor-close! ed state))

(define (cycle-sidebar-command ed state)
  (editor-cycle-sidebar-view! ed state))

(define (next-tab-command ed state)
  (editor-cycle-editor-view! ed state 1))

(define (prev-tab-command ed state)
  (editor-cycle-editor-view! ed state -1))

(define (toggle-sidebar-command ed state)
  (editor-toggle-sidebar! ed state))

(define layout-command-table
  (keys
   [(key 'w 'ctrl) (key 'left)  (split-command 'left)]
   [(key 'w 'ctrl) (key 'right) (split-command 'right)]
   [(key 'w 'ctrl) (key 'up)    (split-command 'up)]
   [(key 'w 'ctrl) (key 'down)  (split-command 'down)]
   [(key 'x 'ctrl) (key 'left)  (focus-command 'left)]
   [(key 'x 'ctrl) (key 'right) (focus-command 'right)]
   [(key 'x 'ctrl) (key 'up)    (focus-command 'up)]
   [(key 'x 'ctrl) (key 'down)  (focus-command 'down)]
   [(key 'd 'ctrl)              close-command]
   [(key 'x 'ctrl) (key 'b)     cycle-sidebar-command]
   [(key 'x 'ctrl) (key 'n)     next-tab-command]
   [(key 'x 'ctrl) (key 'p)     prev-tab-command]
   [(key 'b 'ctrl)              toggle-sidebar-command]))

(define layout-plugin
  (make-plugin
   #:id 'layout
   #:state #t
   #:commands layout-command-table))
