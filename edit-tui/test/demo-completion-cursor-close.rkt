#lang racket

;;; 补全打开后，目标文档光标被鼠标/导航移动（没有文本变化）应自动关闭。
;;; 文本输入导致的版本变化由 refine 更新 anchor，不应误关。

(require rackunit
         "../main.rkt"
         "../demo/completion-docs.rkt")

(define engine demo-engine)
(define-values (s1 _panels) (sync-ui/panels! demo-state engine))
(define-values (s2 _overlays) (prepare-demo! s1 engine))

;; 打开补全。
(define-values (s3 _acts) (step s2 (key-event (key 'o 'ctrl))))
(check-not-false (hash-ref (app-state-store s3) 'demo/completion #f))

;; 模拟鼠标点在同一个 target editor 内：光标动，文档 version 不变。
(define s4
  (run-actions s3 engine
               (list (view-action 'select 1
                                  (selections-one (caret (point 0 0)))))))
(check-not-false (hash-ref (app-state-store s4) 'demo/completion #f))

(define-values (s5 panels) (sync-ui/panels! s4 engine))
(define-values (s6 _ovs) (prepare-demo! s5 engine))
(check-false (hash-ref (app-state-store s6) 'demo/completion #f))
(check-false (app-state-key-owner-stack s6))

(displayln "edit-tui-rebuild/test/demo-completion-cursor-close.rkt: ok")
