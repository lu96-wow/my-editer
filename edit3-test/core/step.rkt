#lang racket

;;; edit3-test/step.rkt —— 装配（boot / 面板 / 编辑 / 分裂 / 区域 / 指针 / 浮窗 / 文件 / 输入行 / 退出）
;;;
;;; 迁移 edit2 的命令系统后，键位也随 edit2：C-s 是分屏前缀，浮窗用 M-j，区域用 C-b。
;;; 每步前先 refresh-panels!（与 runtime 一致，面板是 State 的纯投影）。

(require rackunit racket/list racket/string racket/file
         "../../edit3/core/state.rkt"
         "../../edit3/core/event.rkt"
         "../../edit3/core/effect.rkt"
         "../../edit3/core/layout.rkt"
         "../../edit3/core/border.rkt"
         "../../edit3/core/step.rkt"
         "../../edit3/core/window.rkt"
         "../../edit3/core/panels.rkt"
         "../../edit3/core/render.rkt"
         "../../edit3/core/adapter.rkt")

(define SZ (cons 80 24))
(define (run-ev st ev)
  (call-with-values (lambda () (step (refresh-panels! st) SZ ev)) list))
(define (run1 st ev) (car (run-ev st ev)))
(define (geom st) (layout (state-tiling st) (state-floats st) SZ))
(define (tile-wids st) (node-wids (tiling-root (state-tiling st))))
(define (rect-of st wid)
  (placement-rect (findf (lambda (p) (eqv? wid (placement-wid p))) (geometry-placements (geom st)))))
(define (panel-vid-of st name) (panel-vid st name))

;; boot：编辑区 + 状态栏 + 侧栏(树) = 3 个 tile，焦点在编辑区（wid 0）
(define st0 (boot 80 24))
(check-equal? (length (tile-wids st0)) 3)
(check-equal? (state-focus st0) 0)
(check-true (focused-editor? st0))
(check-equal? (all-wids st0) '(2 0 1))

;; 编辑：文本进焦点窗
(define st1 (run1 st0 (text-event "abc")))
(check-equal? (view-string (state-ed st1) (focused-vid st1)) "abc")

;; 面板 = State 的纯投影：状态栏显示文档名 + 行列；树列目录
(define st1p (refresh-panels! st1))
(check-true (regexp-match? #rx"scratch" (view-string (state-ed st1p) (panel-vid st1p "*status*"))))
(check-true (regexp-match? #rx"1:4" (view-string (state-ed st1p) (panel-vid st1p "*status*"))))
(check-true (> (string-length (view-string (state-ed st1p) (panel-vid st1p "*tree*"))) 0))

;; 渲染：geometry → pieces 含编辑文本 + 竖线分隔
(define-values (_s rends sels) (render st1p (geom st1p) #f))
(define out (apply string-append (map piece-text (append rends sels))))
(check-true (regexp-match? #rx"abc" out))
(check-true (for/or ([r (in-list (border-runs (geom st1p)))]) (regexp-match? #rx"│" (list-ref r 2))))

;; 拖侧栏/编辑区边界（axis h，pos 28，树 wid = 2）：侧栏宽度变，编辑区吸收
(define tw0 (rect-w (rect-of st1p 2)))
(define st2 (run1 st1p (cursor-event 'press 'left 28 5)))
(check-true (dragging? (state-drag st2)))
(define st3 (run1 st2 (cursor-event 'move 'left 36 5)))
(check-equal? (rect-w (rect-of st3 2)) (+ tw0 8))
(check-true (idle? (state-drag (run1 st3 (cursor-event 'release 'left 36 5)))))

;; 面板不可编辑：焦点切到状态栏（wid 1），输入被忽略
(define st5 (refresh-panels! (struct-copy state st3 [focus 1])))
(define before (view-string (state-ed st5) (layout-tile-vid (state-tiling st5) 1)))
(check-equal? (view-string (state-ed (run1 st5 (text-event "X")))
                           (layout-tile-vid (state-tiling st5) 1))
              before)

;; 分裂：C-s 进前缀，方向键分裂焦点 → 4 个 tile，焦点在新窗
(define st6a (run1 st1p (key-event 's '(ctrl))))
(check-equal? (feature-ref st6a 'prefix #f) 'split)
(define st6 (run1 st6a (key-event 'right '())))
(check-equal? (length (tile-wids st6)) 4)
(check-not-equal? (state-focus st6) (state-focus st1p))
;; 交点：C-s 的竖线与编辑/状态栏横线相交 → ┴
(check-true (for/or ([r (in-list (border-runs (geom st6)))]) (regexp-match? #rx"┴" (list-ref r 2))))

;; 浮窗：M-j 开日志浮窗（floats 1、焦点在它、z>0、有框）；Esc 关
(define st7 (run1 st1p (key-event 'j '(alt))))
(check-equal? (length (state-floats st7)) 1)
(check-equal? (state-focus st7) (float-wid (car (state-floats st7))))
(check-true (for/or ([p (in-list (geometry-placements (geom st7)))])
                   (and (eqv? (state-focus st7) (placement-wid p)) (positive? (placement-z p)))))
(check-true (for/or ([r (in-list (border-runs (geom st7)))]) (regexp-match? #rx"┌" (list-ref r 2))))
(define st8 (run1 st7 (key-event 'escape '())))
(check-equal? (length (state-floats st8)) 0)

;; 区域：C-b 隐/显侧栏（贴根），C-l 显隐日志（贴主区、在状态栏之上）
(define st9 (run1 st1p (key-event 'b '(ctrl))))
(check-equal? (length (tile-wids st9)) 2)
(define st10 (run1 st9 (key-event 'b '(ctrl))))
(check-equal? (length (tile-wids st10)) 3)
(define st11 (run1 st1p (key-event 'l '(ctrl))))
(check-equal? (length (tile-wids st11)) 4)   ; 侧栏 + 编辑 + 日志 + 状态栏
(check-equal? (length (all-wids st11)) 4)

;; 侧栏成员互斥：M-b 切到 *buffers*，焦点在侧栏面板
(define st12 (run1 st1p (key-event 'b '(alt))))
(check-equal? (wid-panel-name st12 (state-focus st12)) "*buffers*")

;; 关编辑窗：C-d（焦点是编辑区）——窗口保留为「空窗」（vid = #f），不让状态栏跳位
(define st13 (run1 st1p (key-event 'd '(ctrl))))
(check-equal? (length (tile-wids st13)) 3)
(check-false (layout-tile-vid (state-tiling st13) 0))
(check-equal? (wid-of-vid st13 (panel-vid st13 "*status*")) 1)

;; 文件树：导航 + Enter 打开文件
(define tmpdir (make-temporary-file "ed3tree~a" 'directory))
(display-to-file "hello\nworld\n" (build-path tmpdir "a.txt") #:exists 'truncate)
(define ft0 (boot 80 24 #:root tmpdir #:name #f))
(define ft1 (run1 ft0 (key-event 't '(alt))))          ; 聚焦侧栏文件树
(check-equal? (wid-panel-name ft1 (state-focus ft1)) "*tree*")
;; 行：根(0) / a.txt(1) → down 一行 + Enter 打开
(define ft2 (run1 ft1 (key-event 'down '())))
(check-equal? (panel-line ft2 "*tree*") 1)
(define ft3 (run1 ft2 (key-event 'enter '())))
(check-equal? (focused-vid ft3) (wid-vid ft3 0))
(define fdid (view-did (state-ed ft3) (focused-vid ft3)))
(check-equal? (document-name (state-ed ft3) fdid) (path->string (build-path tmpdir "a.txt")))
(check-equal? (view-string (state-ed ft3) (focused-vid ft3)) "hello\nworld\n")

;; 保存：编辑后 M-s → save-file effect，落盘
(define ft4 (run1 ft3 (text-event "ZZ")))
(define ft5 (run1 ft4 (key-event 's '(alt))))
(define save-eff
  (for/first ([e (in-list (let-values ([(s es) (step (refresh-panels! ft4) SZ (key-event 's '(alt)))]) es))]
              #:when (save-file? e)) e))
(check-true (save-file? save-eff))
(check-equal? (save-file-text save-eff) "ZZhello\nworld\n")

;; 输入行：脏文档 C-q → 打开 prompt（状态栏 pane 显示 *input*）；答 n → quit
(define ft6 (run1 ft5 (text-event "Q")))     ; 再改脏
(define q1 (run1 ft6 (key-event 'q '(ctrl))))
(check-true (and (feature-ref q1 'prompt #f) #t))
(check-true (regexp-match? #rx"save" (view-string (state-ed (refresh-panels! q1))
                                                  (panel-vid (refresh-panels! q1) "*input*"))))
(define q2 (run1 q1 (text-event "n")))
(define-values (q3 qeffs) (step (refresh-panels! q2) SZ (key-event 'enter '())))
(check-true (for/or ([e (in-list qeffs)]) (quit-effect? e)))

;; 纯 quit（无脏文档）
(define q (run-ev (boot 80 24) (key-event 'q '(ctrl))))
(check-true (quit-effect? (car (cadr q))))

;; 清理临时目录
(delete-directory/files tmpdir)

(displayln "edit3/step.rkt: all tests passed")
