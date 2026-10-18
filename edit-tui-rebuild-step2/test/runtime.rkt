#lang racket

;;; edit-tui/test/runtime.rkt —— 块 6：bootstrap / dispatch / effect / state 闭环
;;;
;;; 不启动终端：直接喂 base/event，跑 process-events（dispatch + 解释 effect）。
;;; 运行：racket edit-tui/test/runtime.rkt

(require rackunit
         racket/async-channel
         "../command/key.rkt"
         "../command/mouse.rkt"
         (prefix-in app: "../base/event.rkt")
         "../base/id.rkt"
         "../base/transition.rkt"
         "../model/layout.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/chrome.rkt"
         "../model/input.rkt"
         "../plugins/resource/model.rkt"
         "../effects/engine.rkt"
         "../chrome/slot.rkt"
         "../bootstrap/defaults.rkt"
         "../plugins/builtin.rkt"
         "../runtime/run.rkt"
         "../../core/editor/ops.rkt")

(define did (doc-id 1))
(define vid (view-id 1))
(define erid (region-id 1))
(define srid (region-id 2))

(define engine (make-engine))
(void (engine-create-doc! engine did "main.rkt" "abc\n"))
(void (engine-create-view! engine vid did))

(define ws0
  (let* ([ws (workspace-empty)]
         [ws (workspace-add-doc ws did (make-doc-meta "main.rkt" #:path "/tmp/main.rkt"))]
         [ws (workspace-add-view ws vid (view-meta did (hash)))]
         [ws (workspace-add-region ws erid (region erid (list (view-member vid)) vid 'editor))])
    ws))

(define s-base
  (make-state #:workspace ws0 #:ids (make-id-counter 2 2 3 1)))
(define s-chrome (install-chrome! engine s-base srid))
(define lay
  (make-split 'tb
              (list (make-leaf erid (flex 1))
                    (make-leaf srid (fixed 1) #:borders '()))
              (flex 1)))
(define s0
  (state-set-focus
   (state-set-workspace s-chrome
                        (struct-copy workspace (state-workspace s-chrome) [layout lay]))
   vid))

(define inbox (make-async-channel))
(define (feed s . evs)
  (transition-state (process-events default-env engine inbox s evs)))
(define (feed-on eng s . evs)
  (transition-state (process-events default-env eng (make-async-channel) s evs)))
(define (plain c) (app:key-event (key c)))
(define (ctrl c)  (app:key-event (key c 'ctrl)))
(define (meta c)  (app:key-event (key c 'alt)))
(define (ev) (make-engine-view engine))

;;; ════════════════ 编辑 / 导航 ════════════════

(define s1 (feed s0 (plain 'x)))
(check-equal? (engine-view-doc-text (ev) did) "xabc\n")
(check-equal? (engine-view-view-point-column (ev) vid) 1)

(define s2 (feed s1 (plain 'y)))
(check-equal? (engine-view-doc-text (ev) did) "xyabc\n")

(define s3 (feed s2 (app:internal-event 'noop '())))
(check-equal? (engine-view-doc-text (ev) did) "xyabc\n")

(define s4 (feed s3 (plain 'left)))
(check-equal? (engine-view-view-point-column (ev) vid) 1)
(define s5 (feed s4 (plain 'home)))
(check-equal? (engine-view-view-point-column (ev) vid) 0)
(define s6 (feed s5 (plain 'end)))
(check-equal? (engine-view-view-point-column (ev) vid) 5)

;; undo / redo：最后一次编辑是插入 y（当前文本 xyabc），undo 回到 xabc
(define s7 (feed s6 (ctrl 'z)))
(check-equal? (engine-view-doc-text (ev) did) "xabc\n")
(define s8 (feed s7 (ctrl 'y)))
(check-equal? (engine-view-doc-text (ev) did) "xyabc\n")

;; resize
(define s9 (feed s8 (app:resize-event 30 100)))
(check-equal? (window-rows (state-window s9)) 30)
(check-equal? (window-cols (state-window s9)) 100)

;; paste（先 Home，确保落点确定）
(define s9a (feed s9 (plain 'home)))
(define s10 (feed s9a (app:paste-event "P")))
(check-equal? (engine-view-doc-text (ev) did) "Pxyabc\n")

;;; ════════════════ 前缀 + 未绑定键：不卡住、不插入、只报告 ════════════════

(define u0-text (engine-view-doc-text (ev) did))
(define u1 (feed s10 (ctrl 'x)))                 ; C-x：前缀
(check-equal? (input-pending (state-input u1)) (list (key 'x 'ctrl)))
(define u2 (feed u1 (plain 'p)))                 ; C-x p：未绑定
(check-equal? (input-pending (state-input u2)) '())
(check-equal? (chrome-message (state-chrome u2)) "unbound: C-x p")
(check-equal? (engine-view-doc-text (ev) did) u0-text)   ; 没有插入 p
;; 下一个键恢复正常
(define u3 (feed u2 (plain 'q)))
(check-equal? (engine-view-doc-text (ev) did) "Pqxyabc\n")
(check-equal? (chrome-message (state-chrome u3)) "")     ; 上一次的提示已被清掉

;;; ════════════════ 切分 / 焦点 / 关闭 ════════════════

;; C-w →：向右拆出一个**空** region（不复制 document，也不新增 view）
(define s11 (feed s10 (ctrl 'w) (app:key-event (key 'right))))
(check-equal? (hash-count (engine-views engine)) 3)          ; view 没变多
(check-equal? (hash-count (workspace-views (state-workspace s11))) 3)
(check-equal? (hash-count (workspace-regions (state-workspace s11))) 3)
(define split-rid (state-focus s11))
(check-true (region-id? split-rid))
(check-equal? (workspace-region-views (state-workspace s11) split-rid) '())
(check-equal? (region-role (workspace-region (state-workspace s11) split-rid)) 'editor)

;; M-left：焦点从空 region 回到左边有文档的 view
(define s12 (feed s11 (meta 'left)))
(check-equal? (state-focus s12) vid)

;; M-right 再回到空 region（焦点可以停在空 region 上）
(define s12b (feed s12 (meta 'right)))
(check-equal? (state-focus s12b) split-rid)

;; 点击空 region 也只聚焦它（没有 view 可以落点）
(define s13 (feed s12 (app:mouse-event (mouse 'press 'left) 1 75)))
(check-equal? (state-focus s13) split-rid)

;; 在空 region 里 C-n：新 document 装进去
(define s13n (feed s13 (ctrl 'n)))
(check-equal? (length (workspace-region-views (state-workspace s13n) split-rid)) 1)
(check-true (view-id? (state-focus s13n)))

;; C-w C-w：关闭这个新 view，region 留着（变成空 region）
(define s14 (feed s13n (ctrl 'w) (ctrl 'w)))
(check-equal? (hash-count (workspace-views (state-workspace s14))) 3)
(check-equal? (state-focus s14) vid)

;;; ════════════════ 点击定位 / 拖选 ════════════════

;; 真实 loop 会先 sync view；headless 里手动 sync 到一个足够大的尺寸。
(engine-sync-view! engine vid 80 20)
;; 把 viewport 水平滚动归零（headless 里之前 view 只有 1×1，可能留下 left-column）
(view-set-left-column! (engine-view-object engine vid) 0)
(define s-click (feed s14 (app:mouse-event (mouse 'press 'left) 1 2)))
(check-equal? (state-focus s-click) vid)
(check-equal? (engine-view-view-point-column (ev) vid) 1)
(check-not-false (input-gesture (state-input s-click)))
(check-eq? (gesture-kind (input-gesture (state-input s-click))) 'select)

(define s-drag (feed s-click (app:mouse-event (mouse 'move #f) 1 4)))
(check-equal? (engine-view-view-point-column (ev) vid) 3)
(check-equal? (gesture-owner (input-gesture (state-input s-drag))) vid)

(define s-release (feed s-drag (app:mouse-event (mouse 'release 'left) 1 4)))
(check-false (input-gesture (state-input s-release)))

;;; ════════════════ 关闭 region / panel ════════════════

;; 再拆一个空 region，然后 M-w 关闭整个 region（不是只关 view）
(define s-split2 (feed s-release (ctrl 'w) (app:key-event (key 'right))))
(check-equal? (hash-count (workspace-views (state-workspace s-split2))) 3)
(check-equal? (hash-count (workspace-regions (state-workspace s-split2))) 4)
(define new-rid (state-focus s-split2))
(check-true (region-id? new-rid))
(define s-close-region (feed s-split2 (meta 'w)))
(check-equal? (hash-count (workspace-views (state-workspace s-close-region))) 3)
(check-equal? (hash-count (workspace-regions (state-workspace s-close-region))) 3)
(check-false (tree-contains? (workspace-layout (state-workspace s-close-region)) new-rid))
(check-equal? (state-focus s-close-region) vid)

;;; ════════════════ 边界：最后一个 editor region ════════════════

;; keep-last：只剩一个 editor region 时，不删 region，只把 view 摘出来（保留资源）。
(define eng-last (make-engine))
(define did-l (doc-id 1))
(define vid-l (view-id 1))
(define rid-l (region-id 1))
(void (engine-create-doc! eng-last did-l "last.rkt" "last view
"))
(void (engine-create-view! eng-last vid-l did-l))
(define ws-last
  (let* ([ws (workspace-empty)]
         [ws (workspace-add-doc ws did-l (make-doc-meta "last.rkt"))]
         [ws (workspace-add-view ws vid-l (view-meta did-l (hash)))]
         [ws (workspace-add-region ws rid-l
                                   (region rid-l (list (view-member vid-l)) vid-l 'editor))])
    (struct-copy workspace ws [layout (make-leaf rid-l)])))
(define s-last
  (state-set-focus (make-state #:workspace ws-last
                               #:ids (make-id-counter 2 2 2 1))
                   vid-l))
(define s-last-closed (feed-on eng-last s-last (meta 'w)))
(check-true (tree-contains? (workspace-layout (state-workspace s-last-closed)) rid-l))
(check-not-false (workspace-region (state-workspace s-last-closed) rid-l))
(check-equal? (workspace-region-views (state-workspace s-last-closed) rid-l) '())
(check-not-false (workspace-view (state-workspace s-last-closed) vid-l))
(check-false (state-focus s-last-closed))
(check-true (engine-view-exists? eng-last vid-l))

;; 空 region 仍然可以接收新 document/view
(define s-last-new (feed-on eng-last s-last-closed (ctrl 'n)))
(check-equal? (workspace-region-views (state-workspace s-last-new) rid-l)
              (list (view-id 2)))
(check-equal? (state-focus s-last-new) (view-id 2))
(check-true (engine-view-exists? eng-last (view-id 2)))
(check-true (tree-contains? (workspace-layout (state-workspace s-last-new)) rid-l))

;;; ════════════════ 退出 ════════════════

(define s15 (feed s-close-region (ctrl 'q)))
(check-not-false (state-confirm s15))
;; nall + Enter：跳过所有 dirty docs，然后执行 quit
(define s15a (feed s15 (plain #\n)))
(define s15b (feed s15a (plain #\a)))
(define s15c (feed s15b (plain #\l)))
(define s15d (feed s15c (plain #\l)))
(define s16 (feed s15d (app:key-event (key 'enter))))
(check-true (runtime-quit? (state-runtime s16)))

(displayln "edit-tui runtime: ok")
