#lang racket

;;; lab/command/default.rkt —— 默认命令表（通用操作）
;;;
;;; 统一操作：切换焦点、移动指针 / 翻页、基本编辑、撤销、剪贴板、视图、保存、退出。
;;; 每文档表可以覆盖这里的同名 binding；未命中的回落到这里。
;;; 文本 / 可打印键的「自插入」不在这张表里，是派发层的兜底（见 dispatch.rkt）。

(require
 "base.rkt"
 "table.rkt"
 "../effect.rkt"
 "../input.rkt"
 "../model/edit.rkt"
 "../model/session.rkt"
 "../model/view.rkt"
 "../model/document.rkt"
 "../model/tree.rkt")

(provide default-table)

;; 修饰键常量
(define m0 (modifiers #f #f #f #f))
(define mS (modifiers #f #f #t #f))
(define mC (modifiers #t #f #f #f))
(define mA (modifiers #f #t #f #f))

;; 作用在焦点视图上的命令：f : (session vid -> session)。
(define (view-cmd name f)
  (make-command name
    (lambda (s ctx in)
      (define a (active-view-id s))
      (if a (values (f s a) '()) (values s '())))))

;; 与视图无关的命令：f : (session -> session)。
(define (session-cmd name f)
  (make-command name (lambda (s ctx in) (values (f s) '()))))

;; 保存焦点文档：有路径 → 发 io-save，并（乐观）标保存点；无路径 → 无操作。
(define (save-active s ctx in)
  (define a (active-view-id s))
  (cond
    [(not a) (values s '())]
    [else
     (define did (view-document-id s a))
     (define path (document-path s did))
     (if path
         (values (document-mark-saved s did) (list (io-save path did)))
         (values s '()))]))

(define default-table
  (make-table
   (list
    ;; ---------- 移动指针 ----------
    (cons (binding 'left m0)  (view-cmd 'left  (lambda (s v) (view-move! s v 'left))))
    (cons (binding 'right m0) (view-cmd 'right (lambda (s v) (view-move! s v 'right))))
    (cons (binding 'up m0)    (view-cmd 'up    (lambda (s v) (view-move! s v 'up))))
    (cons (binding 'down m0)  (view-cmd 'down  (lambda (s v) (view-move! s v 'down))))
    (cons (binding 'home m0)  (view-cmd 'home  (lambda (s v) (view-move! s v 'home))))
    (cons (binding 'end m0)   (view-cmd 'end   (lambda (s v) (view-move! s v 'end))))

    ;; ---------- Shift+方向 = 扩选 ----------
    (cons (binding 'left mS)  (view-cmd 'extend-left  (lambda (s v) (view-move! s v 'left #t))))
    (cons (binding 'right mS) (view-cmd 'extend-right (lambda (s v) (view-move! s v 'right #t))))
    (cons (binding 'up mS)    (view-cmd 'extend-up    (lambda (s v) (view-move! s v 'up #t))))
    (cons (binding 'down mS)  (view-cmd 'extend-down  (lambda (s v) (view-move! s v 'down #t))))
    (cons (binding 'home mS)  (view-cmd 'extend-home  (lambda (s v) (view-move! s v 'home #t))))
    (cons (binding 'end mS)   (view-cmd 'extend-end   (lambda (s v) (view-move! s v 'end #t))))

    ;; ---------- 翻页 ----------
    (cons (binding 'pageup m0)   (view-cmd 'page-up   (lambda (s v) (view-page! s v 'up))))
    (cons (binding 'pagedown m0) (view-cmd 'page-down (lambda (s v) (view-page! s v 'down))))

    ;; ---------- 编辑 ----------
    (cons (binding 'backspace m0) (view-cmd 'backspace view-backspace!))
    (cons (binding 'delete m0)    (view-cmd 'delete    view-delete!))
    (cons (binding 'enter m0)     (view-cmd 'newline   (lambda (s v) (view-insert! s v "\n"))))
    (cons (binding 'tab m0)       (view-cmd 'tab       (lambda (s v) (view-insert! s v "\t"))))

    ;; ---------- 撤销 / 重做 ----------
    (cons (binding #\z mC) (view-cmd 'undo view-undo!))
    (cons (binding #\y mC) (view-cmd 'redo view-redo!))

    ;; ---------- 剪贴板 / 选区 ----------
    (cons (binding #\c mC) (view-cmd 'copy view-copy!))
    (cons (binding #\v mC) (view-cmd 'paste view-paste!))
    (cons (binding #\x mC) (view-cmd 'cut view-cut!))
    (cons (binding #\a mC) (view-cmd 'select-all view-select-all!))

    ;; ---------- 切换焦点 ----------
    (cons (binding 'left mA)  (session-cmd 'focus-left  (lambda (s) (focus-neighbor! s 'left))))
    (cons (binding 'right mA) (session-cmd 'focus-right (lambda (s) (focus-neighbor! s 'right))))
    (cons (binding 'up mA)    (session-cmd 'focus-up    (lambda (s) (focus-neighbor! s 'up))))
    (cons (binding 'down mA)  (session-cmd 'focus-down  (lambda (s) (focus-neighbor! s 'down))))
    (cons (binding #\o mC)    (session-cmd 'focus-cycle focus-cycle!))
    (cons (binding #\b mC)    (session-cmd 'toggle-tree session-toggle-file-tree))
    (cons (binding #\t mC)    (session-cmd 'switch-tree sidebar-switch!))   ; 侧栏切换文件树/文档树

    ;; ---------- 视图 ----------
    (cons (binding #\\ mC) (session-cmd 'split-view split-active-view!))
    (cons (binding #\w mC) (session-cmd 'close-view close-active-view!))

    ;; ---------- 文档 / 应用 ----------
    (cons (binding #\s mC) (make-command 'save save-active))
    (cons (binding #\q mC) (make-command 'quit
                                         (lambda (s ctx in) (values s (list (quit)))))))))
