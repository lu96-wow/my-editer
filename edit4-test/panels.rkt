#lang racket

;;; edit4-test/panels.rkt —— 面板：纯投影 + 集中写回

(require rackunit
         racket/list racket/file racket/path
         "../edit4/core/world.rkt"
         "../edit4/content/content.rkt"
         (only-in "../edit4/content/engine.rkt" view-string insert!)
         "../edit4/view/panels.rkt"
         "../edit4/app.rkt")

(define (panel-proj w name)
  (for/first ([x (in-list (project-panels base-panels w))] #:when (equal? name (car x))) x))

;;; ---------- 临时目录里放一个文件 ----------

(define dir (make-temporary-file "ed4panel~a" 'directory))
(display-to-file "x\n" (build-path dir "a.txt") #:exists 'truncate)

(define w0 (boot #:text "" #:name "*scratch*" #:root dir))

;; status 面板包含文档名
(define st (panel-proj w0 "*status*"))
(check-true (and st (regexp-match? #rx"scratch" (caddr st))))
;; tree 面板包含目录里的文件
(define tr (panel-proj w0 "*tree*"))
(check-true (and tr (regexp-match? #rx"a\\.txt" (caddr tr))))

;; 写回后，面板文档真的能看到内容
(define ed (content-ed (world-content w0)))
(commit-panels! ed (project-panels base-panels w0))
(define tvid (content-panel-vid (world-content w0) "*tree*"))
(check-true (regexp-match? #rx"a\\.txt" (view-string ed tvid)))

;;; ---------- 脏标记进 status ----------

(define evid (content-vid-of (world-content w0) 0))
(insert! ed evid "hello")
(define st2 (panel-proj w0 "*status*"))
;; 注意：w0 的 content 是同一个引擎盒，insert! 已改变文本，故 status 投影应带 *
(check-true (and st2 (regexp-match? #rx"\\*" (caddr st2))))

(displayln "edit4/panels.rkt: all tests passed")
