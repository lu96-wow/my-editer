#lang racket

;;; edit3-test/plugin.rkt —— 插件装配（契约：op / panel / region / key-table / boot）

(require rackunit racket/list racket/file
         "../../edit3/core/extension.rkt"
         "../../edit3/core/step.rkt"
         "../../edit3/core/panels.rkt"
         "../../edit3/core/event.rkt"
         "../../edit3/core/layout.rkt"
         "../../edit3/plugins/catalog.rkt"
         "../../edit3/plugins/demo.rkt")

(define SZ (cons 80 24))
(define (run1 st ev) (call-with-values (lambda () (step (refresh-panels! st) SZ ev)) (lambda (s e) s)))
(define (tile-count st) (length (node-wids (tiling-root (state-tiling st)))))

;; 启用 demo 插件：面板被创建、boot 被跑
(define st0 (boot 80 24 #:plugins (list demo-plugin)))
(check-true (and (panel-vid st0 "*demo*") #t))
(check-equal? (feature-ref st0 'demo-count 0) 0)
;; 基础面板照旧
(check-true (and (panel-vid st0 "*status*") #t))
(check-true (and (panel-vid st0 "*tree*") #t))

;; 插件贡献的 op 通过插件键表触发（M-y → demo-bump）
(define st1 (run1 st0 (key-event 'y '(alt))))
(check-equal? (feature-ref st1 'demo-count 0) 1)
(define st1p (refresh-panels! st1))
(check-true (regexp-match? #rx"count: 1" (view-string (state-ed st1p) (panel-vid st1p "*demo*"))))

;; 插件贡献的区域可由插件键显隐（M-u → region-toggle demo）
(define n0 (tile-count st0))
(define st2 (run1 st0 (key-event 'u '(alt))))
(check-true (region-visible? st2 'demo))
(check-equal? (tile-count st2) (add1 n0))
(define st3 (run1 st2 (key-event 'u '(alt))))
(check-false (region-visible? st3 'demo))
(check-equal? (tile-count st3) n0)

;; 不启用插件时没有 demo 面板
(define st4 (boot 80 24))
(check-false (panel-vid st4 "*demo*"))

;; 未知插件名 → 报错（不静默）
(check-exn exn:fail? (lambda () (plugins-by-names '(no-such-plugin))))

;;; ---------- 文档打开时插件匹配 + 组合 ----------
(define tmpdir (make-temporary-file "ed3plugin~a" 'directory))
(display-to-file "x\n" (build-path tmpdir "a.demo") #:exists 'truncate)

;; 第二个插件：也匹配 .demo，贡献一个会覆盖 demo 同槽绑定的表
(define (p2-hit _ctx st _ev _args) (values (feature-set st 'p2-hit 1) '()))
(define p2
  (make-plugin #:name 'p2
               #:ops (list (cons 'p2-hit p2-hit))
               #:doc-key-matchers (list (cons '(ext "demo")
                                             '(((key g alt) always (p2-hit)))))))

(define d0 (boot 80 24 #:root tmpdir #:name #f #:plugins (list demo-plugin p2)))
(define d1 (run1 d0 (key-event 't '(alt))))       ; 聚焦文件树
(define d2 (run1 d1 (key-event 'down '())))       ; 根(0) → a.demo(1)
(define d3 (run1 d2 (key-event 'enter '())))      ; 打开 → 匹配 + on-open
(check-true (and (focused-vid d3) #t))
(check-true (and (focused-keymap d3) #t))         ; 该 document 挂了键表
(check-equal? (feature-ref d3 'demo-opened "-")
              (format "~a" (build-path tmpdir "a.demo")))   ; on-open 生效
;; 组合：p2 表叠在 demo 表之后 → M-g 走 p2（而不是 demo-bump）
(define d4 (run1 d3 (key-event 'g '(alt))))
(check-equal? (feature-ref d4 'p2-hit 0) 1)
(check-equal? (feature-ref d4 'demo-count 0) 0)
(delete-directory/files tmpdir)

(displayln "edit3/plugin.rkt: all tests passed")
