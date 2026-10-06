#lang racket

;;; lab-rebuild/smoke-undo.rkt —— 撤销粒度（输入合并）集成（无终端）
;;;
;;; 验证外部编辑层通过 core 的 merge-tag 定粒度：
;;;   · 连续非空白字符合并成一步；
;;;   · 空白（空格 / 换行）是中断：空白并进前一段后封口；
;;;   · undo / redo 在命令层（Ctrl+Z / Ctrl+Y）表现正确。

(require rackunit
         racket/file
         racket/path
         racket/string
         "../core/editor.rkt"
         "app/app.rkt"
         "base/input.rkt"
         "ui/mode.rkt"
         "core/state.rkt"
         "core/edit-panes.rkt"
         "core/actions.rkt")

(define root (simplify-path (path->complete-path (make-temporary-file "undo~a" 'directory))))

(define a (app-init root 100 30))
(define (send e) (app-handle-input a e))
(define (ed) (app-ed a))

(define (open! name)
  (define p (build-path root name))
  (with-output-to-file p #:exists 'replace (lambda () (display "#lang racket/base\n")))
  (app-open-path! a p)
  (define vid (app-edit-active a))
  (set-app-focus! a vid)
  (editor-view-set-point! (ed) vid (point 1 0))       ; 空行 = 文档末尾
  vid)

(define (type! text) (for ([ch (in-string text)]) (send (key-event ch no-mods))))
(define (undo!) (send (key-event 'z (mods #t #f #f))))
(define (redo!) (send (key-event 'y (mods #t #f #f))))

;;; ---------- 空白是中断：["foo "] ["bar"] ----------

(define vid (open! "words.rkt"))
(type! "foo bar")
(check-equal? (editor-view-string (ed) vid) "#lang racket/base\nfoo bar")
(undo!)                                                ; 去掉 "bar"
(check-equal? (editor-view-string (ed) vid) "#lang racket/base\nfoo ")
(undo!)                                                ; 去掉 "foo "
(check-equal? (editor-view-string (ed) vid) "#lang racket/base\n")
(redo!)
(check-equal? (editor-view-string (ed) vid) "#lang racket/base\nfoo ")
(redo!)
(check-equal? (editor-view-string (ed) vid) "#lang racket/base\nfoo bar")

;;; ---------- 单词内合并：undo 一次删光 ----------

(define vid2 (open! "word.rkt"))
(type! "xyz")
(check-equal? (editor-view-string (ed) vid2) "#lang racket/base\nxyz")
(undo!)
(check-equal? (editor-view-string (ed) vid2) "#lang racket/base\n")

;;; ---------- 换行也是中断（Enter → insert-string） ----------

(define vid3 (open! "lines.rkt"))
(type! "ab")
(send (key-event 'escape no-mods))                      ; 先关补全弹层，Enter 才是换行
(send (key-event 'enter no-mods))                      ; 换行
(type! "cd")
(check-equal? (editor-view-string (ed) vid3) "#lang racket/base\nab\ncd")
(undo!)                                                ; 去掉 "cd"
(check-equal? (editor-view-string (ed) vid3) "#lang racket/base\nab\n")
(undo!)                                                ; 去掉 "ab\n"
(check-equal? (editor-view-string (ed) vid3) "#lang racket/base\n")

;;; ---------- 非编辑动作不并入打字：光标移动后另起一步 ----------

(define vid4 (open! "nav.rkt"))
(type! "ef")
(send (key-event 'left no-mods))                       ; 光标左移
(type! "g")
(check-equal? (editor-view-string (ed) vid4) "#lang racket/base\negf")
(undo!)                                                ; 只去掉 "g"
(check-equal? (editor-view-string (ed) vid4) "#lang racket/base\nef")
(undo!)                                                ; 再去掉 "ef"
(check-equal? (editor-view-string (ed) vid4) "#lang racket/base\n")

(displayln "lab smoke-undo: ok")
