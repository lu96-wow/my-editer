#lang racket

(require "../../core/editor.rkt"
         "../base/input.rkt"
         "../core/state.rkt"
         "../core/actions.rkt"
         "../plugin/seam.rkt"
         "../plugin/input/api.rkt"
         "../plugin/input/registry.rkt")

;;; lab-rebuild/command/registry.rkt —— 命令注册表（功能 → 命令名）
;;;
;;; 三层里的中间层：
;;;   功能核心   core/actions/*   唯一改 app / editor 的地方
;;;   命令注册   command/registry.rkt 本文件：命令名 → handler（统一 (event app . args) -> any）
;;;   默认键位   config/keys.rkt  binding → 命令描述（符号 / (符号 . 参数)），纯数据
;;;
;;; 键位表只写「命令名」，不认识 core / actions / state：把命令名换成行为只在这里做。
;;; 带参数的命令用列表描述： (nav left #t) / (insert-string "\n") / (prefix "C-p" table)。
;;;
;;; 与 core 的边界：本层可以调 actions、可以碰插件接缝（编辑后同步影子）。
;;; core 不反过来 require 本层。

(provide command-invoke)

;;; ================= 注册表 =================

(define commands (make-hash))

(define-syntax-rule (define-command name proc)
  (hash-set! commands 'name proc))

;; spec = name | (name . args)（见 command/table.rkt）
(define (command-invoke spec event app)
  (define name (if (pair? spec) (car spec) spec))
  (define args (if (pair? spec) (cdr spec) '()))
  (define h (hash-ref commands name #f))
  (unless h (error 'command-invoke "未知命令: ~a" name))
  (apply h event app args))

;;; ================= 小工具 =================

(define (ed a) (app-ed a))
(define (focus a) (app-focus a))

(define (event-text e)
  (cond [(key-event? e) (string (key-event-key e))]
        [(paste-event? e) (paste-event-text e)]
        [else ""]))

;; 跑一次编辑并把产生的增量交给插件层（只有文本编辑会返回 changes）。
(define (edit! a thunk)
  (define vid (focus a))
  (define-values (changes _ok?) (thunk))
  (when (and vid (pair? changes)) (plugin-note-change! a vid changes)))

;;; ================= 编辑 =================

(define (cmd-insert e a)
  (define text (event-text e))
  (define r (input-plugins-text! enabled-input-plugins a text))
  (cond
    [(not r) (edit! a (lambda () (editor-view-insert! (ed a) (focus a) text)))]
    [(pair? r) (plugin-note-change! a (focus a) r)]     ; 插件已改好，只需同步影子
    [else (void)]))                                      ; 插手但没改文本（如跳过闭括号）

(define (cmd-paste-text e a)
  (edit! a (lambda () (editor-view-paste-text! (ed a) (focus a) (event-text e)))))

(define (cmd-insert-string e a s)
  (edit! a (lambda () (editor-view-insert! (ed a) (focus a) s))))

(define (cmd-backspace e a)
  (define r (input-plugins-backspace! enabled-input-plugins a))
  (cond
    [(not r) (edit! a (lambda () (editor-view-backspace! (ed a) (focus a))))]
    [(pair? r) (plugin-note-change! a (focus a) r)]
    [else (void)]))

(define (cmd-delete e a) (edit! a (lambda () (editor-view-delete! (ed a) (focus a)))))

;; 方向移动：dir = left/right/up/down/home/end；extend? = #t 时带选扩展（Shift+方向）。
(define nav-procs
  (hash 'left  editor-view-left!  'right editor-view-right!
        'up    editor-view-up!    'down  editor-view-down!
        'home  editor-view-home!  'end   editor-view-end!))

(define (cmd-nav e a dir extend?)
  (define p (hash-ref nav-procs dir))
  (p (ed a) (focus a) extend?))

(define (cmd-select-all e a) (editor-view-select-all! (ed a) (focus a)))
(define (cmd-copy e a)       (editor-view-copy! (ed a) (focus a)))
(define (cmd-cut e a)        (edit! a (lambda () (editor-view-cut! (ed a) (focus a)))))
(define (cmd-paste e a)      (edit! a (lambda () (editor-view-paste! (ed a) (focus a)))))
;; undo/redo 只返回 ok?，没有 change → 插件层下个 tick 整篇重发（开 / 重置影子）。
(define (cmd-undo e a)       (editor-view-undo! (ed a) (focus a)))
(define (cmd-redo e a)       (editor-view-redo! (ed a) (focus a)))

;;; ================= 焦点移动 =================

(define (cmd-focus e a dir) (app-move-focus! a dir))

;;; ================= app =================

(define (cmd-quit e a)          (app-quit! a))
(define (cmd-toggle-sidebar e a) (app-toggle-sidebar! a))
(define (cmd-save e a)          (app-save! a))
(define (cmd-split-tb e a)      (app-split! a 'tb))
(define (cmd-split-lr e a)      (app-split! a 'lr))
(define (cmd-pane-close e a)    (app-pane-close! a))

;; 前缀键：label 只是底部提示；tables 是下一键只查的命令表（可嵌套）。
(define (cmd-prefix e a label tables) (app-prefix-begin! a label tables))

;;; ================= 文件树 =================

(define (cmd-toggle-left e a)   (app-toggle-left! a))
(define (cmd-tree-activate e a) (app-tree-activate! a))
(define (cmd-tree-new-file e a) (app-tree-new-file! a))
(define (cmd-tree-new-dir e a)  (app-tree-new-dir! a))
(define (cmd-tree-delete e a)   (app-tree-delete! a))

;;; ================= 文档 / 视图列表 =================

(define (cmd-bufs-activate e a) (app-bufs-activate! a))
(define (cmd-bufs-new-view e a) (app-bufs-new-view! a))
(define (cmd-bufs-close e a)    (app-bufs-close! a))

;;; ================= 模态 =================

(define (cmd-commit e a) (app-commit! a))
(define (cmd-cancel e a) (app-cancel! a))

;; 确认型：y / n 收 bool，其余吞掉。绑定词表把字符塌成 'text，所以回看原始事件。
(define (cmd-answer e a)
  (define k (and (key-event? e) (key-event-key e)))
  (cond [(eqv? k #\y) (app-answer! a #t)]
        [(eqv? k #\n) (app-answer! a #f)]
        [else (void)]))

(define (cmd-noop e a) (void))

;;; ================= 注册 =================

(define-command insert        cmd-insert)
(define-command paste-text    cmd-paste-text)
(define-command insert-string cmd-insert-string)
(define-command backspace     cmd-backspace)
(define-command delete        cmd-delete)
(define-command nav           cmd-nav)
(define-command select-all    cmd-select-all)
(define-command copy          cmd-copy)
(define-command cut           cmd-cut)
(define-command paste         cmd-paste)
(define-command undo          cmd-undo)
(define-command redo          cmd-redo)
(define-command focus         cmd-focus)
(define-command quit          cmd-quit)
(define-command toggle-sidebar cmd-toggle-sidebar)
(define-command save          cmd-save)
(define-command split-tb      cmd-split-tb)
(define-command split-lr      cmd-split-lr)
(define-command pane-close    cmd-pane-close)
(define-command prefix        cmd-prefix)
(define-command toggle-left   cmd-toggle-left)
(define-command tree-activate cmd-tree-activate)
(define-command tree-new-file cmd-tree-new-file)
(define-command tree-new-dir  cmd-tree-new-dir)
(define-command tree-delete   cmd-tree-delete)
(define-command bufs-activate cmd-bufs-activate)
(define-command bufs-new-view cmd-bufs-new-view)
(define-command bufs-close    cmd-bufs-close)
(define-command commit        cmd-commit)
(define-command cancel        cmd-cancel)
(define-command answer        cmd-answer)
(define-command noop          cmd-noop)
