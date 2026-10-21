#lang racket

;;; 布局交互 demo 的 headless 验证：拆分 / 显隐 / 拖缝。
(require rackunit
         "../main.rkt"
         "../demo/interactive.rkt"
         "demo-editor.rkt")

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
(define ed-state (open-editor-into-demo demo-state demo-engine "hello"))
(define-values (s9 a9) (step ed-state (key-event (key 'x))))
(check-equal? (map view-action-kind a9) '(insert))
(check-equal? (view-action-view-id (car a9)) 1)
(check-equal? (view-action-data (car a9)) #"x")
;; 大写保留
(define-values (_s10 a10) (step ed-state (key-event (key 'X))))
(check-equal? (view-action-data (car a10)) #"X")

;;; ---------- demo 的编辑器：点击 buffer -> 光标落点 ----------
(define r (hash-ref (layout-panel-rects (app-state-layout ed-state)
                                        (app-state-area ed-state))
                    'editor))
(check-true (rect-contains? r (+ (rect-x r) 2) (+ (rect-y r) 2)))
(define-values (_s11 a11)
  (step ed-state (mouse-event 'press (+ (rect-y r) 2) (+ (rect-x r) 2))))
(check-equal? (map view-action-kind a11) '(point))
;; 内容区坐标（投影去掉边框后的相对坐标，和 content-hit 一致）
(define-values (hit-id hit-row hit-col)
  (layout-content-hit (app-state-layout ed-state)
                         (app-state-area ed-state)
                         (+ (rect-y r) 2) (+ (rect-x r) 2)))
(check-equal? hit-id 'editor)
(check-equal? (view-action-data (car a11)) (list hit-row hit-col #f))

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

;; 列不限制在行首：点在第 2 列就停在第 2 列
(check-equal? (engine-view-point-column demo-engine 10) 2)
(define-values (s-right a-right) (step s-click (key-event (key 'right))))
(check-equal? (map view-action-kind a-right) '(nav))
(define s-right* (sync-ui! (run-actions s-right demo-engine a-right) demo-engine))
(check-equal? (engine-view-point-column demo-engine 10) 3)
(check-equal? (filetree-cursor (hash-ref (app-state-store s-right*) 'filetree)) 2)

;; Home / End 就是普通 buffer 的行首 / 行尾
(define-values (s-home a-home) (step s-right* (key-event (key 'home))))
(define s-home* (sync-ui! (run-actions s-home demo-engine a-home) demo-engine))
(check-equal? (engine-view-point-column demo-engine 10) 0)
(define row-len (string-length (filetree-line-text
                                (list-ref (filetree-rows (hash-ref (app-state-store s-home*) 'filetree)) 2))))
(define-values (s-end a-end) (step s-home* (key-event (key 'end))))
(define s-end* (sync-ui! (run-actions s-end demo-engine a-end) demo-engine))
(check-equal? (engine-view-point-column demo-engine 10) row-len)

;; 点击后键盘继续动：点到的行成为新起点（导航也是普通 view-action）
(define-values (s-down a-down) (step s-click (key-event (key 'down))))
(check-equal? (map view-action-kind a-down) '(nav))
(define s-down* (sync-ui! (run-actions s-down demo-engine a-down) demo-engine))
(check-equal? (filetree-cursor (hash-ref (app-state-store s-down*) 'filetree)) 3)

;; 点最后一行以下：落到最近有效行（最后一行），列按点击列。
;; 用「行数」定位空白行；目录条目多到占满面板时没有空白行，跳过。
(define ft-row-count
  (length (filetree-rows (hash-ref (app-state-store s-click) 'filetree))))
(when (< ft-row-count (rect-h ft-rect))
  (define-values (s-blank a-blank)
    (click s-click (+ (rect-y ft-rect) ft-row-count) (+ (rect-x ft-rect) 2)))
  (check-equal? (map view-action-kind a-blank) '(point))
  (check-equal? (filetree-cursor (hash-ref (app-state-store s-blank) 'filetree))
                (sub1 ft-row-count))
  (check-equal? (engine-view-point-line demo-engine 10) (sub1 ft-row-count))
  (check-equal? (engine-view-point-column demo-engine 10) 2))

;;; ---------- C-d：最后一个 editor 只清 view；多个 editor 时删 panel ----------
(define-values (s-cd a-cd) (step ed-state (key-event (key 'd 'ctrl))))
(check-equal? a-cd '())
(check-not-false (layout-panel (app-state-layout s-cd) 'editor))
(check-false (panel-view (layout-panel (app-state-layout s-cd) 'editor)))
(check-false (app-state-focus-resource s-cd))
(check-not-false (resource-ref (app-state-resources s-cd) 1))

(define-values (s-split _a-split) (step ed-state (key-event (key 'w 'ctrl))))
(define-values (s-split2 _a-split2) (step s-split (key-event (key 'right))))
(define-values (s-cd2 _a-cd2) (step s-split2 (key-event (key 'd 'ctrl))))
(check-false (layout-panel (app-state-layout s-cd2) 'editor))
(check-not-false (layout-panel (app-state-layout s-cd2) 100))

(displayln "edit-tui-rebuild/test/layout-demo.rkt: ok")
