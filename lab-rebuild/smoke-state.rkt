#lang racket

;;; lab-rebuild/smoke-state.rkt —— state 行增量更新回归
;;;
;;; 反复移动焦点 / 换文件名 / 加前缀提示后，验证：
;;;   · 文本长度 == 主区宽（padding 正确、无残留）
;;;   · 整行只读、整行 state face（增量补齐了新插入格）
;;;   · 状态栏不进撤销栈（undo 不改变它）
(require rackunit
         racket/file
         racket/path
         "../core/editor.rkt"
         "app/app.rkt"
         "core/state.rkt"
         "core/panes.rkt"
         "core/edit-panes.rkt"
         "core/actions.rkt"
         "core/paths.rkt"
         "base/input.rkt"
         "ui/tree.rkt"
         "ui/slot.rkt")

(define root (simplify-path (path->complete-path (make-temporary-file "st~a" 'directory))))
(with-output-to-file (build-path root "aa.txt") #:exists 'replace (lambda () (display "AAA")))
(with-output-to-file (build-path root "bbbbbb.txt") #:exists 'replace (lambda () (display "BBBBBB")))
(define a (app-init root 80 24 #:sidebar-width 24))
(define (send e) (app-handle-input a e))
(define (ed) (app-ed a))
(define (svid) (panes-state (app-panes a)))
(define (tvid) (panes-tree (app-panes a)))
(define (evid) (app-edit-active a))

(define (check-state! note)
  (void (app-render a))                                     ; 全渲染：会设 layout/宽高
  (define s (editor-view-string (ed) (svid)))
  (define did (editor-view-document-id (ed) (svid)))
  (define doc (editor-document-handle (ed) did))
  ;; 横向 / 纵向不能滚：否则渲染从第 2 列开始，首字符（tree/edit）会看不见。
  (check-equal? (editor-view-left-column (ed) (svid)) 0 (format "~a: left-column" note))
  (check-equal? (editor-view-top-line (ed) (svid)) 0 (format "~a: top-line" note))
  (check-equal? (string-length s) (app-main-w a) (format "~a: 长度" note))
  (for ([c (in-range (string-length s))])
    (check-true (document-readonly-at? doc 0 c) (format "~a: 只读 ~a" note c))
    (check-true (equal? (document-highlight-at doc 0 c) 'state) (format "~a: face ~a" note c))))

(check-state! "init")

;; 反复移动焦点：树 → 编辑 → 树 → …（触发多次增量拼接 / 删除）
(for ([_ (in-range 3)])
  (send (key-event 'b (mods #t #f #f)))
  (check-state! "to-edit")
  (send (key-event 'b (mods #t #f #f)))
  (check-state! "to-tree"))

;; 打开文件并把光标右移，让 行:列 变化，文件名段也变
(define (tree-line-of name)
  (for/first ([e (in-list (tree-entries (app-tree a)))] [i (in-naturals)]
              #:when (equal? (entry-name e) name)) i))
(editor-view-set-point! (ed) (tvid) (point (tree-line-of "aa.txt") 0))
(send (key-event 'enter no-mods))
(send (key-event 'b (mods #t #f #f)))                     ; 焦点到编辑格
(for ([_ (in-range 4)]) (send (key-event 'right no-mods)))
(check-state! "edit-moved")
(check-not-false (string-contains? (editor-view-string (ed) (svid)) "aa.txt"))

;; 换到更长的文件名（前缀相同 → 走 suffix 差异）；焦点先移回树再打开
(send (key-event 'b (mods #t #f #f)))                      ; edit → tree
(editor-view-set-point! (ed) (tvid) (point (tree-line-of "bbbbbb.txt") 0))
(send (key-event 'enter no-mods))
(send (key-event 'b (mods #t #f #f)))
(check-state! "long-name")
(check-not-false (string-contains? (editor-view-string (ed) (svid)) "bbbbbb.txt"))

;; 前缀提示：文本加长 + 还原
(send (key-event 'p (mods #t #f #f)))
(check-state! "prefix-on")
(check-not-false (string-contains? (editor-view-string (ed) (svid)) "[C-p-]"))
(send (key-event 'escape no-mods))
(check-state! "prefix-off")

;; 状态栏不该有撤销栈：undo 不应改变 state 行
(editor-view-undo! (ed) (svid))
(check-state! "after-undo")

(displayln "state-incremental: ok")
