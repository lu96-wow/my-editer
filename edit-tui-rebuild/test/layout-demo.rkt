#lang racket

;;; 布局交互 demo 的 headless 验证：拆分 / 显隐 / 拖缝。
(require rackunit
         "../main.rkt"
         "../demo/interactive.rkt")

(define (visible-ids s)
  (layout-visible-panel-ids (app-state-layout s)))

;;; ---------- filetree 已安装并有内容 ----------
(define synced (sync-ui! demo-state demo-engine))
(define ft (hash-ref (app-state-store synced) 'filetree))
(check-true (> (length (filetree-rows ft)) 0))
(check-true (> (string-length (engine-view-text demo-engine 10)) 0))

;;; ---------- split ----------
(define-values (s1 a1) (step demo-state (key-event (key 'w 'ctrl))))
(check-equal? a1 '())
(check-equal? (app-state-pending s1) (list (key 'w 'ctrl)))
(define-values (s2 a2) (step s1 (key-event (key 'right))))
(check-equal? a2 '())
(check-not-false (memv 100 (visible-ids s2)))
(check-equal? (panel-kind (layout-panel (app-state-layout s2) 100)) 'editor)
(check-equal? (app-state-pending s2) '())

;;; ---------- hide / show filetree ----------
(define-values (s3 a3) (step demo-state (key-event (key 'b 'ctrl))))
(check-equal? a3 '())
(check-false (layout-panel-visible? (app-state-layout s3) 'filetree))
(define-values (s4 a4) (step s3 (key-event (key 'b 'ctrl))))
(check-equal? a4 '())
(check-true (layout-panel-visible? (app-state-layout s4) 'filetree))

;;; ---------- drag filetree seam ----------
(define-values (l-flex ok-flex?) (layout-panel-set-fixed (app-state-layout demo-state) 'filetree 'w #f))
(check-true ok-flex?)
(define s5 (struct-copy app-state demo-state [layout l-flex]))
(define seam (layout-seam-at l-flex (app-state-area s5) 0 30))
(check-not-false seam)
(define seam-x (rect-x (seam-rect seam)))

(define-values (s6 a6) (step s5 (mouse-event 'press 0 seam-x)))
(check-equal? a6 '())
(check-not-false (app-state-drag s6))
(define-values (s7 a7) (step s6 (mouse-event 'move 0 (+ seam-x 5))))
(check-equal? a7 '())
(check-not-false (app-state-drag s7))
(define-values (s8 a8) (step s7 (mouse-event 'release 0 (+ seam-x 5))))
(check-equal? a8 '())
(check-false (app-state-drag s8))

(define widths
  (for/list ([id (in-list (layout-visible-panel-ids (app-state-layout s8)))])
    (define r (hash-ref (layout-panel-rects (app-state-layout s8)
                                            (app-state-area s8))
                        id))
    (cons id (rect-w r))))
;; filetree 从 40 -> 45
(check-equal? (cdr (assoc 'filetree widths)) 35)

;;; ---------- demo 的编辑器：打字 -> 自插入 ----------
(define-values (s9 a9) (step demo-state (key-event (key 'x))))
(check-equal? (map view-action-kind a9) '(insert))
(check-equal? (view-action-view-id (car a9)) 1)
(check-equal? (view-action-data (car a9)) #"x")
;; 大写保留
(define-values (_s10 a10) (step demo-state (key-event (key 'X))))
(check-equal? (view-action-data (car a10)) #"X")

;;; ---------- demo 的编辑器：点击 buffer -> 光标落点 ----------
(define r (hash-ref (layout-panel-rects (app-state-layout demo-state)
                                        (app-state-area demo-state))
                    'editor))
(check-true (rect-contains? r (+ (rect-x r) 2) (+ (rect-y r) 2)))
(define-values (_s11 a11)
  (step demo-state (mouse-event 'press (+ (rect-y r) 2) (+ (rect-x r) 2))))
(check-equal? (map view-action-kind a11) '(point))
;; 内容区坐标（投影去掉边框后的相对坐标，和 content-hit 一致）
(define-values (hit-id hit-row hit-col)
  (layout-content-hit-at (app-state-layout demo-state)
                         (app-state-area demo-state)
                         (+ (rect-y r) 2) (+ (rect-x r) 2)))
(check-equal? hit-id 'editor)
(check-equal? (view-action-data (car a11)) (list hit-row hit-col))

;; ---------- 文件树就是普通 buffer：点哪行，光标（view point）就到哪行 ----------
(define synced2 (sync-ui! demo-state demo-engine))
(let-values ([(c b) (render-frame synced2 demo-engine #f)])   ; 首帧写入 viewport 尺寸
  (void c) (void b))
(define ft-rect (hash-ref (layout-panel-rects (app-state-layout synced2)
                                              (app-state-area synced2))
                          'filetree))
(define (click state row col)
  (let-values ([(s1 a1) (step state (mouse-event 'press row col))])
    (values (sync-ui! (run-actions s1 demo-engine a1) demo-engine) a1)))

(define-values (s-click a-click)
  (click synced2 (+ (rect-y ft-rect) 2) (+ (rect-x ft-rect) 2)))
(check-equal? (layout-focus (app-state-layout s-click)) 'filetree)
;; 点击 -> 一个普通的 point action，没有文件树专用分支
(check-equal? (map view-action-kind a-click) '(point))
(check-equal? (filetree-cursor (hash-ref (app-state-store s-click) 'filetree)) 2)

;; 点最后一行以下：view-screen-position->point 返回 #f，光标不动（和编辑器一致）
(define-values (s-blank a-blank)
  (click s-click (+ (rect-y ft-rect) (rect-h ft-rect) -2) (+ (rect-x ft-rect) 2)))
(check-equal? (map view-action-kind a-blank) '(point))
(check-equal? (filetree-cursor (hash-ref (app-state-store s-blank) 'filetree)) 2)

;; 点击后键盘继续动：点到的行成为新起点（dirty? 路径推回 view）
(define-values (s-down a-down) (step s-click (key-event (key 'down))))
(check-equal? (map view-action-kind a-down) '())
(define s-down* (sync-ui! (run-actions s-down demo-engine a-down) demo-engine))
(check-equal? (filetree-cursor (hash-ref (app-state-store s-down*) 'filetree)) 3)

(displayln "edit-tui-rebuild/test/layout-demo.rkt: ok")
