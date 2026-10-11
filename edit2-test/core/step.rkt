#lang racket

;;; edit2-test/step.rkt —— edit2/step.rkt 的外部测试（控制流 / 路由 / 关闭）

(require rackunit
         "../../edit2/core/step.rkt"
         "../../edit2/core/event.rkt"
         "../../edit2/core/effect.rkt"
         "../../edit2/core/route.rkt"
         "../../edit2/core/layout.rkt"
         "../../edit2/core/state.rkt"
         "../../edit2/core/adapter.rkt"
         "../../edit2/core/panels.rkt")

(define routes (app-routes))
(define (fresh) (boot "abc" "t" 60 16 #:root (current-directory)))
(define (ctx-of st)
  (define ps (layout (state-layout st) (cons 60 16)))
  (set-layout! (state-ed st) ps)   ; 模拟渲染：把尺寸落到 view（否则面板视口高=1）
  (ctx (cons 60 16) ps))
(define (run1 st ev)
  (define st* (refresh-panels! st))   ; 模拟运行时每帧先刷面板
  (call-with-values (lambda () (step routes (ctx-of st*) st* ev)) (lambda (s e) s)))
(define (run-ev st ev)
  (call-with-values (lambda () (step routes (ctx-of st) st ev)) list))

;; 输入文本 → core 里变了（每个用例从 fresh 起：core 编辑原地 mutate）
(define st1 (run1 (fresh) (text-event "XY")))
(check-equal? (document-string (state-ed st1) (focused-did st1)) "XYabc")

;; 回归：*scratch* 是普通缓冲区，不是面板（否则按键与点击定位都被守卫/面板分支吞掉）
(define ssc (boot "abc" "*scratch*" 60 16 #:root (current-directory)))
(check-false (panel-name ssc (state-focus ssc)))
(check-equal? (document-string (state-ed (run1 ssc (text-event "Z"))) (focused-did ssc)) "Zabc")

;; 状态栏显示相对文件树根的路径
(define rt (current-directory))
(define ssp (set-focused-path! (boot "abc" "t" 60 16 #:root rt)
                               (build-path rt "edit2" "step.rkt")))
(define ssp2 (refresh-panels! ssp))
(check-true (regexp-match? #rx"edit2[/\\\\]step\\.rkt"
                           (view-string (state-ed ssp2) (panel-vid ssp2 "*status*"))))

;; backspace
(define st2 (run1 (run1 (fresh) (text-event "XY")) (key-event 'backspace '())))
(check-equal? (document-string (state-ed st2) (focused-did st2)) "Xabc")

;; 分屏
(define st3 (run1 (fresh) (key-event 'w '(ctrl))))
(check-equal? (length (view-id-list (state-ed st3))) 7)   ; 1 编辑 + 5 面板，分屏后 +1
;; 焦点切换
(define st4 (run1 (fresh) (key-event 't '(alt))))
(check-equal? (panel-name st4 (state-focus st4)) "*tree*")
(define st5 (run1 st4 (key-event 'e '(alt))))
(check-false (panel-name st5 (state-focus st5)))
;; 侧栏：tree / buffers 共享同一区域，C-b 整体显隐
(define stb (run1 (fresh) (key-event 'b '(alt))))     ; M-b：侧栏切到缓冲区
(check-equal? (region-visible-vid stb 'sidebar) (panel-vid stb "*buffers*"))
(define stb2 (run1 stb (key-event 'b '(ctrl))))       ; C-b：隐藏侧栏
(check-false (region-visible? stb2 'sidebar))
(define stb3 (run1 stb2 (key-event 'b '(ctrl))))      ; 再 C-b：显示回上次成员（缓冲区）
(check-equal? (region-visible-vid stb3 'sidebar) (panel-vid stb3 "*buffers*"))
;; 面板键不会插进树文字
(define st6 (run1 (run1 (fresh) (key-event 't '(alt))) (text-event "x")))
(check-equal? (panel-name st6 (state-focus st6)) "*tree*")
;; 隐藏侧栏时，聚焦面板被撤 → 焦点回编辑器
(define stf (run1 (fresh) (key-event 't '(alt))))
(define stf2 (run1 stf (key-event 'b '(ctrl))))
(check-false (panel-name stf2 (state-focus stf2)))

;; 一切皆 document：树的选择 = 面板 doc 的光标行；点击/导航都走 document
(define stt0 (fresh))
(define tv (panel-vid stt0 "*tree*"))
(check-equal? (view-line (state-ed stt0) tv) 0)
(define stt1 (run1 (run1 stt0 (key-event 't '(alt))) (key-event 'down '())))
(check-equal? (view-line (state-ed stt1) (panel-vid stt1 "*tree*")) 1)
;; 点击树第 3 行 → 面板 doc 光标落到第 3 行（同一套屏幕→document 定位）
(define stt2 (run1 (fresh) (cursor-event 'press 'left 2 2)))
(check-equal? (view-line (state-ed stt2) (panel-vid stt2 "*tree*")) 2)
;; 指针事件：布局命中 → 定位光标（编辑器窗格从列 28 开始）
(define st0 (fresh))
(define ps (layout (state-layout st0) (cons 60 16)))
(define c (ctx (cons 60 16) ps))
(define stc (call-with-values (lambda () (step routes c st0 (cursor-event 'press 'left 30 0)))
                              (lambda (s e) s)))
(check-false (panel-name stc (state-focus stc)))
(check-equal? (view-col (state-ed stc) (state-focus stc)) 2)
;; 点在树面板上 → 聚焦树，编辑器不动
(define stc2 (call-with-values (lambda () (step routes c st0 (cursor-event 'press 'left 2 0)))
                               (lambda (s e) s)))
(check-equal? (panel-name stc2 (state-focus stc2)) "*tree*")

;; 退出：干净 → 直接 quit-effect
(define r (run-ev (fresh) (key-event 'q '(ctrl))))
(check-true (quit-effect? (car (cadr r))))

;; 退出：脏 → 弹 prompt（不是立刻退）
(define sq (run1 (run1 (fresh) (text-event "Z")) (key-event 'q '(ctrl))))
(check-true (prompt? (state-input sq)))
;; 答 n → 退出
(define sq2 (run-ev (run1 sq (text-event "n")) (key-event 'enter '())))
(check-true (quit-effect? (car (cadr sq2))))

;; 关闭：干净视图 → C-d 直接关
(define sc (run1 (fresh) (key-event 'w '(ctrl))))
(define sc2 (run1 sc (key-event 'd '(ctrl))))
(check-equal? (length (view-id-list (state-ed sc2))) 6)   ; 7 → 6

;; 关闭：脏 → 弹 prompt；答 n 关掉（无文件名不保存）
(define sd (run1 (fresh) (text-event "Z")))
(define sd1 (run1 sd (key-event 'd '(ctrl))))
(check-true (prompt? (state-input sd1)))
(define sd2 (run1 (run1 sd1 (text-event "n")) (key-event 'enter '())))
(check-false (prompt? (state-input sd2)))

;; 关掉所有编辑视图后，状态栏仍固定在底部（编辑区留持久空位，不让 split 塌缩）
(define se (run1 (fresh) (key-event 'd '(ctrl))))
(define sv (panel-vid se "*status*"))
(define pse (layout (state-layout se) (cons 60 16)))
(define sp (for/first ([p (in-list pse)] #:when (eqv? (placement-vid p) sv)) p))
(check-equal? (rect-y (placement-rect sp)) 15)

;; 文件树贴顶：树从第 0 行、高=屏高-状态栏；状态栏全宽贴底
(define sfl (fresh))
(define psfl (layout (state-layout sfl) (cons 60 16)))
(define tp (for/first ([p (in-list psfl)] #:when (eqv? (placement-vid p) (panel-vid sfl "*tree*"))) p))
(define stp (for/first ([p (in-list psfl)] #:when (eqv? (placement-vid p) (panel-vid sfl "*status*"))) p))
(check-equal? (rect-y (placement-rect tp)) 0)
(check-equal? (rect-h (placement-rect tp)) 15)
(check-equal? (rect-y (placement-rect stp)) 15)
(check-equal? (rect-w (placement-rect stp)) 60)

(displayln "edit2/step.rkt: all tests passed")
