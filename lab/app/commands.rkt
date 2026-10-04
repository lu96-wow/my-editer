#lang racket

(require "../../core/editor.rkt"
         "../base/input.rkt"
         "../base/command.rkt"
         "../base/layout/main.rkt"
         "state.rkt"
         "actions.rkt")

;;; lab/app/commands.rkt —— 命令表（binding → handler）
;;;
;;; handler 约定 (event app)：dispatch 直接把 app 当 ctx 透传。
;;; 表本身是纯数据；动作都在 actions.rkt，这里只做「事件 → 调动作」。
;;;
;;; 分层：
;;;   global      焦点移动 + 编辑 + app 级（对所有文档生效）
;;;   按 did      树 / 文档列表 / state 槽（覆盖 global）
;;;   模态表      input-edit-keys / confirm-keys，由 mode-tables 在 dispatch 时叠上

(provide edit-keys focus-keys app-keys readonly-keys
         tree-keys bufs-keys
         input-edit-keys confirm-keys)

;;; ================= 编辑助手 =================

(define (ed* a) (app-ed a))
(define (focused a) (app-focus a))

(define (ev-text e)
  (cond [(key-event? e) (string (key-event-key e))]
        [(paste-event? e) (paste-event-text e)]
        [else ""]))

(define (do-insert e a)
  (editor-view-insert! (ed* a) (focused a) (ev-text e)))
(define (do-nav a f [extend? #f])
  (f (ed* a) (focused a) extend?))

;;; ================= global：编辑 =================

(define edit-keys
  (command-table
   text-binding        (lambda (e a) (do-insert e a))
   (key 'enter)        (lambda (e a) (editor-view-insert! (ed* a) (focused a) "\n"))
   (key 'tab)          (lambda (e a) (editor-view-insert! (ed* a) (focused a) "\t"))
   (key 'backspace)    (lambda (e a) (editor-view-backspace! (ed* a) (focused a)))
   (key 'delete)       (lambda (e a) (editor-view-delete! (ed* a) (focused a)))
   (key 'left)         (lambda (e a) (do-nav a editor-view-left!))
   (key 'right)        (lambda (e a) (do-nav a editor-view-right!))
   (key 'up)           (lambda (e a) (do-nav a editor-view-up!))
   (key 'down)         (lambda (e a) (do-nav a editor-view-down!))
   (key 'home)         (lambda (e a) (do-nav a editor-view-home!))
   (key 'end)          (lambda (e a) (do-nav a editor-view-end!))
   (key 'left 'shift)  (lambda (e a) (do-nav a editor-view-left! #t))
   (key 'right 'shift) (lambda (e a) (do-nav a editor-view-right! #t))
   (key 'up 'shift)    (lambda (e a) (do-nav a editor-view-up! #t))
   (key 'down 'shift)  (lambda (e a) (do-nav a editor-view-down! #t))
   (key 'home 'shift)  (lambda (e a) (do-nav a editor-view-home! #t))
   (key 'end 'shift)   (lambda (e a) (do-nav a editor-view-end! #t))
   (key 'a 'ctrl)      (lambda (e a) (editor-view-select-all! (ed* a) (focused a)))
   (key 'c 'ctrl)      (lambda (e a) (editor-view-copy! (ed* a) (focused a)))
   (key 'x 'ctrl)      (lambda (e a) (editor-view-cut! (ed* a) (focused a)))
   (key 'v 'ctrl)      (lambda (e a) (editor-view-paste! (ed* a) (focused a)))
   (key 'z 'ctrl)      (lambda (e a) (editor-view-undo! (ed* a) (focused a)))
   (key 'y 'ctrl)      (lambda (e a) (editor-view-redo! (ed* a) (focused a)))))

;;; ================= global：焦点移动 =================

(define (move-focus dir)
  (lambda (e a)
    (define vid (pane-dir (app-focus-panes a) (app-focus a) dir))
    (when vid (set-app-focus! a vid))))

(define focus-keys
  (command-table
   (key 'left 'ctrl)  (move-focus 'left)
   (key 'right 'ctrl) (move-focus 'right)
   (key 'up 'ctrl)    (move-focus 'up)
   (key 'down 'ctrl)  (move-focus 'down)))

;;; ================= global：app =================

(define app-keys
  (command-table
   (key 'q 'ctrl) (lambda (e a) (set-app-quit?! a #t))
   (key 'o 'ctrl) (lambda (e a) (app-toggle-focus! a))
   (key 's 'ctrl) (lambda (e a) (app-save! a))))

;;; ================= 只读面板基表 =================

(define readonly-keys
  (command-table
   text-binding     (lambda (e a) (void))
   (key 'enter)     (lambda (e a) (void))
   (key 'tab)       (lambda (e a) (void))
   (key 'backspace) (lambda (e a) (void))
   (key 'delete)    (lambda (e a) (void))
   (key 'v 'ctrl)   (lambda (e a) (void))
   (key 'x 'ctrl)   (lambda (e a) (void))
   (key 'z 'ctrl)   (lambda (e a) (void))
   (key 'y 'ctrl)   (lambda (e a) (void))))

;;; ================= 文件树 =================

(define tree-keys
  (command-merge
   (list readonly-keys
         (command-table
          (key 'tab)       (lambda (e a) (app-toggle-left! a))
          (key 'enter)     (lambda (e a) (app-tree-activate! a))
          (key 'n 'ctrl)   (lambda (e a) (app-tree-new-file! a))
          (key 'l 'ctrl)   (lambda (e a) (app-tree-new-dir! a))
          (key 'backspace) (lambda (e a) (app-tree-delete! a))))))

;;; ================= 文档 / 视图列表 =================

(define bufs-keys
  (command-merge
   (list readonly-keys
         (command-table
          (key 'tab)   (lambda (e a) (app-toggle-left! a))
          (key 'enter) (lambda (e a) (app-bufs-activate! a))))))

;;; ================= 模态表 =================
;;
;; 输入型：enter 提交、escape 取消、tab 吞掉；字符 / 退格落全局 edit-keys。
;; 确认型：y / n 收 bool，其余吞掉。

(define input-edit-keys
  (command-table
   (key 'enter)  (lambda (e a) (app-commit! a))
   (key 'escape) (lambda (e a) (app-cancel! a))
   (key 'tab)    (lambda (e a) (void))))

(define (confirm-text e a)
  (define k (and (key-event? e) (key-event-key e)))
  (cond [(eqv? k #\y) (app-answer! a #t)]
        [(eqv? k #\n) (app-answer! a #f)]
        [else (void)]))

(define confirm-keys
  (command-merge
   (list readonly-keys
         (command-table
          text-binding  confirm-text
          (key 'escape) (lambda (e a) (app-cancel! a))))))
