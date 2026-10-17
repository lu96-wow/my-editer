#lang racket

;;; edit-tui-rebuild/test/projection.rkt —— 块 5：geometry / status / render
;;;
;;; 运行：racket edit-tui-rebuild/test/projection.rkt

(require rackunit
         "../../edit-tui/command/key.rkt"
         "../../edit-tui/theme/main.rkt"
         "../base/id.rkt"
         "../base/event.rkt"
         "../model/layout.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/input.rkt"
         "../model/chrome.rkt"
         "../effects/engine.rkt"
         "../projection/geometry.rkt"
         "../projection/status.rkt"
         "../projection/render.rkt"
         "../../core/view/base/rect.rkt"
         "../../core/view/panel.rkt")

;;; ════════════════ geometry ════════════════

(define r1 (region-id 1))
(define r2 (region-id 2))
(define r3 (region-id 3))
(define area (rect 0 0 40 10))

;; 左右两栏
(define lay-lr
  (make-split 'lr
              (list (make-leaf r1 (flex 1))
                    (make-leaf r2 (flex 1)))
              (flex 1)))
(define-values (ps-lr cuts-lr) (geometry-solve lay-lr area))
(check-equal? (length ps-lr) 2)
(check-equal? (map region-panel-region ps-lr) (list r1 r2))
(check-true (for/and ([p (in-list ps-lr)])
              (and (>= (rect-w (region-panel-content p)) 1)
                   (>= (rect-h (region-panel-content p)) 1))))
;; 相邻面板共享 1 格接缝
(define p1 (car ps-lr))
(define p2 (cadr ps-lr))
(check-equal? (rect-right (region-panel-rect p1))
              (add1 (rect-x (region-panel-rect p2))))
(check-equal? (length cuts-lr) 1)
(check-not-false (cut-at cuts-lr 0 20))

;; 上下：editor + 固定 1 行 slot（slot 无外边框）
(define lay-tb
  (make-split 'tb
              (list (make-leaf r1 (flex 1))
                    (make-leaf r3 (fixed 1) #:borders '()))
              (flex 1)))
(define-values (ps-tb _cuts-tb) (geometry-solve lay-tb area))
(define editor-p (car ps-tb))
(define slot-p (cadr ps-tb))
(check-equal? (rect-h (region-panel-content slot-p)) 1)
(check-equal? (region-panel-borders slot-p) '(up))
(check-true (> (rect-h (region-panel-content editor-p)) 1))

;; 单叶、无边框：内容 = 外框
(define-values (ps-none _) (geometry-solve (make-leaf r1 #:borders '()) area))
(check-equal? (region-panel-content (car ps-none)) area)

;; 命中
(check-equal? (region-panel-region (region-panel-at ps-lr 0 0)) r1)
(check-equal? (region-panel-region (region-panel-at ps-lr 0 39)) r2)
(check-false (region-panel-at ps-lr 99 99))

;;; ════════════════ status ════════════════

(define eng (make-engine))
(define did (doc-id 1))
(define vid (view-id 1))
(void (engine-create-doc! eng did "main.rkt" "abc\ndef\n"))
(void (engine-create-view! eng vid did))
(define ev (make-engine-view eng))

(define ws0
  (let* ([ws (workspace-empty)]
         [ws (workspace-add-doc ws did (make-doc-meta "main.rkt"
                                                      #:path "/tmp/main.rkt"
                                                      #:mode 'text))]
         [ws (workspace-add-view ws vid (view-meta did (hash)))]
         [ws (workspace-add-region ws r1 (region r1 (list (view-member vid)) vid 'editor))])
    (struct-copy workspace ws [layout (make-leaf r1)])))
(define s0 (state-set-focus (state-set-workspace (state-empty) ws0) vid))

(check-equal? (status-position s0 ev) (cons 1 1))
(check-equal? (status-path s0) "/tmp/main.rkt")
(check-false (status-sequence s0))
(check-true (string-contains? (status-line s0 ev) "1:1"))
(check-true (string-contains? (status-line s0 ev) "/tmp/main.rkt"))

;; pending 优先于 message
(define s1 (state-chrome* (state-input* s0 (λ (i) (input-set-pending i (list (key 'x 'ctrl)))))
                          (λ (c) (chrome-set-message c "msg"))))
(check-equal? (status-sequence s1) "C-x")
(check-true (string-contains? (status-line s1 ev) "C-x"))
(check-false (string-contains? (status-line s1 ev) "msg"))

;; prompt
(define s2 (state-input* s0 (λ (i) (input-set-prompt i (make-prompt 'string #:label "name: " #:text "bob")))))
(check-equal? (prompt-line s2) "name: bob")
(check-equal? (chrome-line s2 ev 'input) "name: bob")
(check-equal? (chrome-line s2 ev 'status) (status-line s2 ev))

;;; ════════════════ render ════════════════

;; 区域：editor + 底部 status slot
(define rid (region-id 1))
(define sid (region-id 2))
(define eng2 (make-engine))
(define did2 (doc-id 1))
(define vid2 (view-id 1))
(void (engine-create-doc! eng2 did2 "main.rkt" "hello\nworld\n"))
(void (engine-create-view! eng2 vid2 did2))

(define ws2
  (let* ([ws (workspace-empty)]
         [ws (workspace-add-doc ws did2 (make-doc-meta "main.rkt" #:path "/tmp/main.rkt"))]
         [ws (workspace-add-view ws vid2 (view-meta did2 (hash)))]
         [ws (workspace-add-region ws rid (region rid (list (view-member vid2)) vid2 'editor))]
         [ws (workspace-add-region ws sid (region sid (list (chrome-member 'status)) 'status 'slot))]
         [ws (struct-copy workspace ws
                          [layout (make-split 'tb
                                              (list (make-leaf rid (flex 1))
                                                    (make-leaf sid (fixed 1) #:borders '()))
                                              (flex 1))])])
    ws))
(define s3 (state-set-focus (state-set-workspace
                             (state-chrome* (make-state #:window (make-window 10 40))
                                            (λ (c) (chrome-set-message c "hello status")))
                             ws2)
                            vid2))

(define-values (panels chromes placements) (project-frame s3 eng2))
(check-equal? (length panels) 2)
(check-equal? (length chromes) 1)
(check-equal? (chrome-entry-line (car chromes)) (status-line s3 (make-engine-view eng2)))
(check-equal? (length placements) 1)

;; 焦点 panel 用 focused-border
(define focused-panel
  (for/first ([p (in-list panels)] #:when (panel-view p)) p))
(check-eq? (panel-face focused-panel) 'focused-border)
(check-eq? (panel-weight focused-panel) 1)

;; 同步 view 尺寸 -> 渲染
(engine-sync-views! eng2 placements)
(define-values (cache bytes) (render-frame s3 eng2 #f))
(check-true (frame-cache? cache))
(check-true (positive? (bytes-length bytes)))
(define text (bytes->string/utf-8 bytes))
(check-true (string-contains? text "hello"))
(check-true (string-contains? text "hello status"))

;; 同一状态再渲染：无变化 -> 空输出
(define-values (cache2 bytes2) (render-frame s3 eng2 cache))
(check-true (frame-cache? cache2))
(check-equal? (bytes-length bytes2) 0)

;; 状态消息变化 -> 只出 chrome 差分（含新文本）
(define s4 (state-chrome* s3 (λ (c) (chrome-set-message c "changed"))))
(define-values (cache3 bytes3) (render-frame s4 eng2 cache2))
(check-true (positive? (bytes-length bytes3)))
(check-true (string-contains? (bytes->string/utf-8 bytes3) "changed"))

;; resize -> 几何变 -> 非空输出
(define s5 (state-set-window s4 (make-window 12 50)))
(define-values (_panels5 _chromes5 placements5) (project-frame s5 eng2))
(engine-sync-views! eng2 placements5)
(define-values (_cache4 bytes4) (render-frame s5 eng2 cache3))
(check-true (positive? (bytes-length bytes4)))

;; chrome 消失 -> 清旧矩形
(define ws6
  (struct-copy workspace (state-workspace s5)
               [layout (make-leaf rid (flex 1))]))
(define s6 (state-set-workspace s5 ws6))
(define-values (_cache5 bytes5) (render-frame s6 eng2 cache3))
(check-true (positive? (bytes-length bytes5)))

(displayln "edit-tui-rebuild projection: ok")
