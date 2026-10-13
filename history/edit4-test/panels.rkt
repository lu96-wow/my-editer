#lang racket

;;; edit4-test/panels.rkt —— 面板：纯投影 + 集中写回

(require rackunit
         racket/list racket/file racket/path
         "../edit4/core/world.rkt"
         "../edit4/content/model.rkt"
         (only-in "../edit4/content/adapter.rkt" view-string insert!)
         "../edit4/view/panel.rkt"
         "../edit4/boot.rkt")

(define (panel-proj w name)
  (define v (content-panel-vid (world-content w) name))
  (for/first ([x (in-list (project-panels base-panels w))] #:when (eqv? v (car x))) (cadr x)))

;;; ---------- 临时目录里放一个文件 ----------

(define dir (make-temporary-file "ed4panel~a" 'directory))
(display-to-file "x\n" (build-path dir "a.txt") #:exists 'truncate)

(define w0 (boot #:text "" #:name "*scratch*" #:root dir))

;; status 面板包含文档名
(check-true (regexp-match? #rx"scratch" (panel-proj w0 "*status*")))
;; tree 面板包含目录里的文件
(check-true (regexp-match? #rx"a\\.txt" (panel-proj w0 "*tree*")))

;; 写回后，面板文档真的能看到内容
(define ed (content-ed (world-content w0)))
(commit-panels! ed (project-panels base-panels w0))
(define tvid (content-panel-vid (world-content w0) "*tree*"))
(check-true (regexp-match? #rx"a\\.txt" (view-string ed tvid)))

;;; ---------- 脏标记进 status ----------

(define evid (content-vid-of (world-content w0) 0))
(insert! ed evid "hello")
;; 注意：w0 的 content 是同一个引擎盒，insert! 已改变文本，故 status 投影应带 *
(check-true (regexp-match? #rx"\\*" (panel-proj w0 "*status*")))

(displayln "edit4/panels.rkt: all tests passed")
