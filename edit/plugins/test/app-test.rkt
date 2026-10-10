#lang racket

;;; edit-rebuild/plugins/test/app-test.rkt —— 内核 + 插件装配 + 渲染冒烟（headless）
;;;
;;;   raco test edit-rebuild/plugins/test/app-test.rkt

(require rackunit
         racket/file
         "../../core/app/app.rkt"
         "../../core/session/session.rkt"
         "../../core/session/adapter.rkt"
         "../../core/session/render.rkt"
         "../../core/session/panel.rkt"
         "../../core/path.rkt"
         "../catalog.rkt"
         "../ui/document.rkt"
         "../ui/ids.rkt")

(define s (app-session 80 24 #:plugins enabled-plugins))

;; 停靠面都装上了
(check-not-false (session-panel-vid s panel-tree))
(check-not-false (session-panel-vid s panel-status))
(check-not-false (session-panel-vid s panel-log))

;; 渲染一帧（无编辑视图）
(define-values (s1 frame rends sels) (session-render s #f))
(check-true (list? rends))
(check-true (> (length rends) 0))

;; 打开文件 → 进编辑区 → 渲染
(define p (make-temporary-file "app-~a.rkt"))
(display-to-file "hello\n" p #:exists 'replace)
(define s2 (session-open-file s (normalize p)))
(define did (session-file-did s2 (normalize p)))
(check-not-false did)
(define vid (session-edit-vid s2))
(check-not-false vid)
(check-equal? (session-view-string s2 vid) "hello\n")

(define-values (s3 frame2 rends2 sels2) (session-render s2 #f))
(check-true (> (length rends2) 0))

(delete-file p)
