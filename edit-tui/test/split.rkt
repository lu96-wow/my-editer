#lang racket

;;; edit-tui/test/split.rkt —— 切分只拆出“空窗口”
;;;
;;; 约定：
;;;   C-w ←/→/↑/↓ 把当前 region 拆成两块，**新的一块是空的**：
;;;     · 不复制 document，也不给同一 document 再加 view；
;;;     · 新 region 的 members = '()，role / 边框跟随源 region；
;;;     · 焦点移到新 region（focus = region-id），之后 C-n / 打开文件就装进去。
;;;
;;; 断言：
;;;   1. 切分不新增 view / document，只新增 region；
;;;   2. 新 region 是空的，role 继承，布局里两块都在；
;;;   3. 空 region 可以被再次切分；
;;;   4. 焦点在空 region 时 C-n 落进去（target-region 认 region-id）；
;;;   5. 焦点能在“有文档的 view”和“空 region”之间来回移动；
;;;   6. role 不可切分（sidebar 文件树面板）时拒绝并提示。

(require rackunit
         racket/async-channel
         "../command/key.rkt"
         (prefix-in app: "../base/event.rkt")
         "../base/id.rkt"
         "../base/transition.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/layout.rkt"
         "../model/chrome.rkt"
         "../effects/engine.rkt"
         "../effects/panel.rkt"
         "../plugins/filetree/plugin.rkt"
         "../projection/render.rkt"
         "../../core/view/panel.rkt"
         "../bootstrap/defaults.rkt"
         "../plugins/builtin.rkt"
         "../runtime/run.rkt")

(define (make-one)
  (define did (doc-id 1))
  (define vid (view-id 1))
  (define rid (region-id 1))
  (define engine (make-engine))
  (void (engine-create-doc! engine did "main.rkt" "abc\n"))
  (void (engine-create-view! engine vid did))
  (define ws
    (let* ([ws (workspace-empty)]
           [ws (workspace-add-doc ws did (make-doc-meta "main.rkt"))]
           [ws (workspace-add-view ws vid (view-meta did (hash)))]
           [ws (workspace-add-region ws rid (region rid (list (view-member vid)) vid 'editor))])
      (struct-copy workspace ws [layout (make-leaf rid)])))
  (define s (state-set-focus (make-state #:workspace ws #:ids (make-id-counter 2 2 2 1)) vid))
  (values engine s did vid rid))

(define (feed engine s . evs)
  (transition-state (process-events default-env engine (make-async-channel) s evs)))
(define (ctrl c) (app:key-event (key c 'ctrl)))
(define (meta c) (app:key-event (key c 'alt)))
(define k-right (app:key-event (key 'right)))
(define k-up    (app:key-event (key 'up)))

;;; ════════════════ 1. 不新增 view / document，只新增 region ════════════════

(define-values (engine s0 did vid rid) (make-one))
(define s1 (feed engine s0 (ctrl 'w) k-right))

(check-equal? (hash-count (workspace-regions (state-workspace s1))) 2)
(check-equal? (hash-count (workspace-views (state-workspace s1))) 1)      ; 没有第二个 view
(check-equal? (hash-count (workspace-docs (state-workspace s1))) 1)       ; 没有第二个 doc
(check-equal? (hash-count (engine-views engine)) 1)

;;; ════════════════ 2. 新 region 是空的；role / 布局 ════════════════

(define new-rid (state-focus s1))
(check-true (region-id? new-rid))
(define ws1 (state-workspace s1))
(define new-reg (workspace-region ws1 new-rid))
(check-equal? (region-members new-reg) '())
(check-equal? (region-active new-reg) #f)
(check-equal? (region-role new-reg) 'editor)
;; 源 region 原样保留
(check-equal? (workspace-region-views ws1 rid) (list vid))
(check-equal? (region-active (workspace-region ws1 rid)) vid)
;; 布局：两块都在，且都在同一颗树里
(check-true (tree-contains? (workspace-layout ws1) rid))
(check-true (tree-contains? (workspace-layout ws1) new-rid))
(check-equal? (length (tree-visible-regions (workspace-layout ws1))) 2)
;; 原 document 仍然只有 1 个 view（没有被“再加一个 view 再拆”）
(check-equal? (length (for/list ([(v vm) (in-hash (workspace-views ws1))]
                                 #:when (equal? (view-meta-doc vm) did))
                        v))
              1)

;; 空 region 也会渲染成一个（空）面板，并且因为焦点在它上面而显示聚焦边框
(define-values (panels _placements) (project-frame s1 engine))
(check-equal? (length panels) 2)
;; 空面板没有 view（panel-view = #f），所以只能按 face 判断“有且只有一个聚焦面板”
(check-equal? (length (for/list ([p (in-list panels)]
                                 #:when (eq? (panel-face p) 'focused-border))
                        p))
              1)
(check-equal? (length (for/list ([p (in-list panels)] #:when (not (panel-view p))) p))
              1)

;;; ════════════════ 3. 空 region 可以再切分 ════════════════

(define s2 (feed engine s1 (ctrl 'w) k-up))
(check-equal? (hash-count (workspace-regions (state-workspace s2))) 3)
(check-true (region-id? (state-focus s2)))
(check-equal? (region-members (workspace-region (state-workspace s2) (state-focus s2))) '())

;;; ════════════════ 4. 焦点在空 region 时 C-n 落进去 ════════════════

(define-values (engine2 s0b did2 vid2 rid2) (make-one))
(define t1 (feed engine2 s0b (ctrl 'w) k-right))
(define empty-rid (state-focus t1))
(define t2 (feed engine2 t1 (ctrl 'n)))
(check-equal? (length (workspace-region-views (state-workspace t2) empty-rid)) 1)
(check-true (view-id? (state-focus t2)))
;; 新的 view 属于新 document，不是原来那个
(define new-vid (state-focus t2))
(check-not-equal? (workspace-doc-of-view (state-workspace t2) new-vid) did2)
;; 原 region 还是原来那个 view
(check-equal? (workspace-region-views (state-workspace t2) rid2) (list vid2))

;;; ════════════════ 5. 焦点在有文档的 view 与空 region 之间移动 ════════════════

(define-values (engine3 s0c did3 vid3 rid3) (make-one))
(define u1 (feed engine3 s0c (ctrl 'w) k-right))
(define erid (state-focus u1))
(define u2 (feed engine3 u1 (meta 'left)))       ; 空 region -> 左边 view
(check-equal? (state-focus u2) vid3)
(define u3 (feed engine3 u2 (meta 'right)))      ; view -> 右边空 region
(check-equal? (state-focus u3) erid)

;;; ════════════════ 6. 不可切分的 role：拒绝 ════════════════

;; 文件树面板（role 'filetree，splittable? = #f）
(define engine4 (make-engine))
(define f1 (install-filetree-panel! engine4 (make-state #:ids (make-id-counter 1 1 1 1))
                                    (region-id 1) (current-directory)))
(define fvid (filetree-panel-view f1))
(define f2 (state-set-workspace
            f1
            (struct-copy workspace (state-workspace f1)
                         [layout (make-leaf (region-id 1))])))
(define f3 (state-set-focus f2 fvid))
(define f4 (feed engine4 f3 (ctrl 'w) k-right))
(check-equal? (hash-count (workspace-regions (state-workspace f4))) 1)
(check-true (string-contains? (chrome-message (state-chrome f4)) "not splittable"))
