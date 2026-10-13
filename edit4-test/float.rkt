#lang racket

;;; edit4-test/float.rkt —— 浮窗：开 / 关 / 切 / 提 / 作用域 / 几何

(require rackunit
         racket/list
         "../edit4/layout.rkt"
         "../edit4/core.rkt"
         "../edit4/content/model.rkt"
         "../edit4/content/adapter.rkt"
         "../edit4/content/commands.rkt"
         "../edit4/content/scopes.rkt"
         "../edit4/view/panel.rkt"
         "../edit4/boot.rkt")

(define SZ (cons 80 24))
(define reg (command-registry-merge base-commands content-commands))
(define km (compose-keymaps (list content-keymap base-keymap)))
(define (mk-ctx w ev)
  (define area (rect 0 0 (car SZ) (cdr SZ)))
  (define tiled (layout (world-layout w) area))
  (define frects (place-floats (geometry-rects tiled) (world-floats w) area))
  (ctx ev SZ (frame tiled frects (car SZ) (cdr SZ))))
(define (run w ev)
  (call-with-values (lambda () (dispatch reg content-scopes km (mk-ctx w ev) w)) list))
(define (W st) (car st))
(define (panel-vid w name) (content-panel-vid (world-content w) name))

(define w0 (boot #:root (current-directory)))

;;; ---------- M-k：浮起文件树 ----------

(define s1 (run w0 (key-event 'k '(alt))))
(check-equal? (length (world-floats (W s1))) 1)
(define fid (float-id (car (world-floats (W s1)))))
(check-equal? (content-vid-of (world-content (W s1)) fid) (panel-vid w0 "*tree*"))
(check-equal? (world-focus (W s1)) fid)                 ; 打开即聚焦
(check-equal? (length (visible-ids (world-layout (W s1)))) 3)   ; 平铺窗不变（折叠 dock 不算）
(check-true (scope-ok? content-scopes (W s1) 'float))

;; 几何：frame 里有该浮窗矩形；命中它返回 float-target
(define-values (_c fr) (ensure-layout empty-layout-cache (world-layout (W s1)) (world-floats (W s1)) SZ))
(define fr1 (frame-float-rect fr fid))
(check-not-false fr1)
(check-equal? (float-target-id (hit-frame fr (rect-x fr1) (rect-y fr1))) fid)

;;; ---------- 点浮起来的树正文 → 移动树面板光标 ----------

(commit-panels! (content-ed (world-content (W s1))) (project-panels base-panels (W s1)))
(define tvid (panel-vid (W s1) "*tree*"))
(define-values (_c3 fr3) (ensure-layout empty-layout-cache (world-layout (W s1)) (world-floats (W s1)) SZ))
(define fr3* (frame-float-rect fr3 fid))
(define c1 (run (W s1) (cursor-event 'press 'left (+ (rect-x fr3*) 2) (+ (rect-y fr3*) 2))))
(check-equal? (view-line (content-ed (world-content (W c1))) tvid) 1)

;;; ---------- 再开同一个 → 提到最上，不重复 ----------

(define s2 (run (W s1) (key-event 'k '(alt))))
(check-equal? (length (world-floats (W s2))) 1)
(check-equal? (float-id (car (world-floats (W s2)))) fid)

;;; ---------- Esc 关闭焦点浮窗 ----------

(define s3 (run (W s1) (key-event 'escape '())))
(check-equal? (length (world-floats (W s3))) 0)

;;; ---------- M-g：开关日志浮窗 ----------

(define g1 (run w0 (key-event 'g '(alt))))
(check-equal? (length (world-floats (W g1))) 1)
(define g2 (run (W g1) (key-event 'g '(alt))))
(check-equal? (length (world-floats (W g2))) 0)

;;; ---------- 两个浮窗：Tab 切换、C-j 提到最上 ----------

(define t1 (run (W (run w0 (key-event 'k '(alt)))) (key-event 'g '(alt))))  ; tree + log
(check-equal? (length (world-floats (W t1))) 2)
(define f-before (world-focus (W t1)))
(define t2 (run (W t1) (key-event 'tab '())))
(check-not-equal? (world-focus (W t2)) f-before)
(define t3 (run (W t2) (key-event 'j '(ctrl))))
(check-equal? (float-id (car (world-floats (W t3)))) (world-focus (W t3)))  ; 焦点浮窗在最上

(displayln "edit4/float.rkt: all tests passed")
