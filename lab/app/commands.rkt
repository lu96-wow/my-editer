#lang racket

(require "../../core/editor.rkt"
         "../base/input.rkt"
         "state.rkt"
         "actions.rkt"
         "plugins.rkt")

;;; lab/app/commands.rkt —— 命令转发层
;;;
;;; 三层里的中间层：
;;;   功能核心   actions.rkt   唯一改 app / editor 的地方
;;;   命令转发   commands.rkt  本文件：把「功能能力」包成命名命令
;;;   默认命令表 keys/*.rkt    binding → 命令，纯数据
;;;
;;; 命令统一约定 (event app) -> any：event 原样透传（文本 / 字符在事件里），app 是唯一状态。
;;; 默认命令表只认这里的名字，**不直接 require core / actions / state**。
;;; 需要参数的命令用工厂： (cmd-nav f) / (cmd-insert-string s) / (cmd-prefix label tables)。

(provide cmd-insert cmd-newline cmd-tab cmd-backspace cmd-delete
         cmd-left cmd-right cmd-up cmd-down cmd-home cmd-end
         cmd-left-select cmd-right-select cmd-up-select cmd-down-select
         cmd-home-select cmd-end-select
         cmd-select-all cmd-copy cmd-cut cmd-paste cmd-undo cmd-redo
         cmd-focus-left cmd-focus-right cmd-focus-up cmd-focus-down
         cmd-toggle-focus cmd-quit cmd-prefix cmd-save
         cmd-split-tb cmd-split-lr cmd-pane-close
         cmd-tree-toggle-left cmd-tree-activate cmd-tree-new-file
         cmd-tree-new-dir cmd-tree-delete
         cmd-bufs-toggle-left cmd-bufs-activate cmd-bufs-new-view cmd-bufs-close
         cmd-commit cmd-cancel cmd-answer cmd-noop)

;;; ================= 小工具 =================

(define (ed a) (app-ed a))
(define (focus a) (app-focus a))

(define (event-text e)
  (cond [(key-event? e) (string (key-event-key e))]
        [(paste-event? e) (paste-event-text e)]
        [else ""]))

;;; ================= 编辑 =================

;; 跑一次编辑并把它产生的增量交给插件层（只有文本编辑会返回 changes）。
(define (edit! a thunk)
  (define-values (changes _ok?) (thunk))
  (when (pair? changes) (app-plugin-note-change! a (focus a) changes)))

(define (cmd-insert e a)
  (edit! a (lambda () (editor-view-insert! (ed a) (focus a) (event-text e)))))

;; 插入固定串（enter / tab）。
(define (cmd-insert-string s)
  (lambda (e a)
    (edit! a (lambda () (editor-view-insert! (ed a) (focus a) s)))))

(define cmd-newline (cmd-insert-string "\n"))
(define cmd-tab     (cmd-insert-string "\t"))

(define (cmd-backspace _ a) (edit! a (lambda () (editor-view-backspace! (ed a) (focus a)))))
(define (cmd-delete _ a)    (edit! a (lambda () (editor-view-delete! (ed a) (focus a)))))

;; 方向移动：extend? = #t 时带选扩展（Shift+方向）。
(define (cmd-nav f [extend? #f])
  (lambda (e a) (f (ed a) (focus a) extend?)))

(define cmd-left (cmd-nav editor-view-left!))
(define cmd-right (cmd-nav editor-view-right!))
(define cmd-up (cmd-nav editor-view-up!))
(define cmd-down (cmd-nav editor-view-down!))
(define cmd-home (cmd-nav editor-view-home!))
(define cmd-end (cmd-nav editor-view-end!))

(define cmd-left-select (cmd-nav editor-view-left! #t))
(define cmd-right-select (cmd-nav editor-view-right! #t))
(define cmd-up-select (cmd-nav editor-view-up! #t))
(define cmd-down-select (cmd-nav editor-view-down! #t))
(define cmd-home-select (cmd-nav editor-view-home! #t))
(define cmd-end-select (cmd-nav editor-view-end! #t))

(define (cmd-select-all _ a) (editor-view-select-all! (ed a) (focus a)))
(define (cmd-copy _ a)       (editor-view-copy! (ed a) (focus a)))
(define (cmd-cut _ a)        (edit! a (lambda () (editor-view-cut! (ed a) (focus a)))))
(define (cmd-paste _ a)      (edit! a (lambda () (editor-view-paste! (ed a) (focus a)))))
;; undo/redo 只返回 ok?，没有 change → 插件层下个 tick 整篇重发（开/重置影子）。
(define (cmd-undo _ a)       (editor-view-undo! (ed a) (focus a)))
(define (cmd-redo _ a)       (editor-view-redo! (ed a) (focus a)))

;;; ================= 焦点移动 =================

(define (cmd-focus-left _ a)  (app-move-focus! a 'left))
(define (cmd-focus-right _ a) (app-move-focus! a 'right))
(define (cmd-focus-up _ a)    (app-move-focus! a 'up))
(define (cmd-focus-down _ a)  (app-move-focus! a 'down))

;;; ================= app =================

(define (cmd-quit _ a)         (app-quit! a))
(define (cmd-toggle-focus _ a) (app-toggle-focus! a))
(define (cmd-save _ a)         (app-save! a))
(define (cmd-split-tb _ a)     (app-split! a 'tb))
(define (cmd-split-lr _ a)     (app-split! a 'lr))
(define (cmd-pane-close _ a)   (app-pane-close! a))

;; 前缀键：label 只是底部提示；tables 是下一键只查的命令表（可嵌套）。
(define (cmd-prefix label tables)
  (lambda (e a) (app-prefix-begin! a label tables)))

;;; ================= 文件树 =================

(define (cmd-tree-toggle-left _ a) (app-toggle-left! a))
(define (cmd-tree-activate _ a)    (app-tree-activate! a))
(define (cmd-tree-new-file _ a)    (app-tree-new-file! a))
(define (cmd-tree-new-dir _ a)     (app-tree-new-dir! a))
(define (cmd-tree-delete _ a)      (app-tree-delete! a))

;;; ================= 文档 / 视图列表 =================

(define (cmd-bufs-toggle-left _ a) (app-toggle-left! a))
(define (cmd-bufs-activate _ a)    (app-bufs-activate! a))
(define (cmd-bufs-new-view _ a)    (app-bufs-new-view! a))
(define (cmd-bufs-close _ a)       (app-bufs-close! a))

;;; ================= 模态 =================

(define (cmd-commit _ a) (app-commit! a))
(define (cmd-cancel _ a) (app-cancel! a))

;; 确认型：y / n 收 bool，其余吞掉。绑定词表把字符塌成 'text，所以回看原始事件。
(define (cmd-answer e a)
  (define k (and (key-event? e) (key-event-key e)))
  (cond [(eqv? k #\y) (app-answer! a #t)]
        [(eqv? k #\n) (app-answer! a #f)]
        [else (void)]))

;; 显式吞键（只读面板 / 模态占位）。
(define (cmd-noop e a) (void))
