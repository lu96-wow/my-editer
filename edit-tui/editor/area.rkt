#lang racket

;;; edit-tui/editor/area.rkt —— 编辑区（editor area）模型
;;;
;;; 当前 layout 是「chrome frame + current editor area」的合成布局。
;;; 非当前编辑区只保存 editor-only layout，不包含 sidebar / status / docs / errors。
;;;
;;; 不变量：
;;;   1. state.layout 始终是当前合成 frame；
;;;   2. state.areas 只保存非当前编辑区；
;;;   3. editor-area.layout 只包含 editor panel；
;;;   4. area-slot 指向 frame 中 editor 子树的直接父 split + side；
;;;   5. 一个 view 在「当前 frame + inactive areas」中最多出现一次；
;;;   6. 每个 area 至少有一个 editor panel（空编辑区用空 panel 表示）。
;;;
;;; 前提：area-slot 的父 split 在 chrome 装配后保持稳定；运行时只隐藏 chrome，
;;; 不删除 / 重排 chrome panel。若以后支持动态 dock，需要重新计算 area-slot。

(require "../core/layout/api.rkt"
         (prefix-in p: "../core/panel/api.rkt")
         "state.rkt")

(provide (struct-out area-slot)
         (struct-out editor-area)
         (struct-out view-location)

         area-slot-for-editor

         make-empty-editor-area
         editor-area-panel-count
         area-base-split-id

         editor-layout-for-area
         editor-with-area-layout
         editor-switch-area

         editor-view-location
         editor-view-in-current-area?
         editor-view-panel-id-in-area)

;;; ════════════════ 类型 ════════════════

;; frame 中 editor 子树的槽位：直接父 split + side。
;; parent-id = #f 表示 editor 子树就是整个 layout root。
(struct area-slot (parent-id side) #:transparent)

;; 非当前编辑区：editor-only layout + 上次离开时的 frame focus。
;; focus 可能是 editor panel，也可能是 chrome panel；加载时会校验可见性。
(struct editor-area (layout focus) #:transparent)

;; view 的全局位置：当前 frame 或某个 inactive area。
(struct view-location (area-id panel-id) #:transparent)

;;; ════════════════ area-slot ════════════════

;; 根据初始 layout + editor panel-id 找到它所在的直接父 split。
;; 返回 #f 表示当前 layout 没有可切换的编辑区槽位。
(define (area-slot-for-editor layout editor-pid)
  (define root (layout-root layout))
  (cond
    [(not root) #f]
    [(and (leaf? root) (equal? (leaf-panel-id root) editor-pid))
     (area-slot #f 'root)]
    [else
     (define-values (parent side)
       (find-parent-split root editor-pid))
     (and parent (area-slot (split-id parent) side))]))

(define (area-slot-child layout slot)
  (define root (layout-root layout))
  (cond
    [(not slot) #f]
    [(not (area-slot-parent-id slot)) root]
    [else
     (define parent (find-split root (area-slot-parent-id slot)))
     (cond
       [(not parent)
        (error 'area-slot-child
               "area slot 的父 split 不存在：~a"
               (area-slot-parent-id slot))]
       [(eq? (area-slot-side slot) 'left) (split-left parent)]
       [(eq? (area-slot-side slot) 'right) (split-right parent)]
       [else
        (error 'area-slot-child
               "area slot side 要是 left / right / root：~a"
               (area-slot-side slot))])]))

;; 把 slot 下的 editor 子树换成 child。
;; → (values new-root ok?)
(define (area-slot-replace-child frame slot child)
  (cond
    [(not slot) (values #f #f)]
    [(not (area-slot-parent-id slot)) (values child #t)]
    [else
     (define parent-id (area-slot-parent-id slot))
     (define side (area-slot-side slot))
     (define-values (root* changed?)
       (update-split (layout-root frame) parent-id
                     (λ (s)
                       (case side
                         [(left) (struct-copy split s [left child])]
                         [(right) (struct-copy split s [right child])]
                         [else
                          (error 'area-slot-replace-child
                                 "area slot side 要是 left / right / root：~a"
                                 side)]))))
     (values root* changed?)]))

;;; ════════════════ 节点遍历 / 空 area ════════════════

(define (node-panel-ids n)
  (cond
    [(not n) '()]
    [(leaf? n) (list (leaf-panel-id n))]
    [else (append (node-panel-ids (split-left n))
                  (node-panel-ids (split-right n)))]))

;; 默认第一个 area 使用 'editor，和 app/layout 的默认 editor panel 保持一致；
;; 其他 area 使用唯一 symbol，便于调试和跨 area 操作。
(define (area-editor-panel-id area-id)
  (if (equal? area-id 1)
      'editor
      (string->symbol (format "area-~a-editor" area-id))))

;; 新 area 的 split-id 起点：必须避开 chrome 已用的 split-id。
(define (area-base-split-id layout)
  (layout-next-split-id layout))

(define (make-empty-editor-area area-id next-split-id)
  (define pid (area-editor-panel-id area-id))
  (define panel
    (p:make-empty-editor-panel pid
                               #:borders '(up down left right)))
  (editor-area
   (make-layout #:root (make-leaf pid)
                #:panels (hash pid panel)
                #:focus pid
                #:next-split-id next-split-id)
   pid))

;; 从当前合成 frame 中抽出当前 area 的 editor 子树。
(define (editor-area-from-frame layout slot focus)
  (define root (area-slot-child layout slot))
  (cond
    [(not root)
     (error 'editor-area-from-frame "当前 frame 的 area 子树为空")]
    [else
     (define pids (node-panel-ids root))
     (define panels
       (for/hash ([pid (in-list pids)])
         (values pid (layout-panel layout pid))))
     (define editor-focus
       (if (and focus (memv focus pids))
           focus
           (car pids)))
     (editor-area
      (make-layout #:root root
                   #:panels panels
                   #:focus editor-focus
                   #:next-split-id (layout-next-split-id layout))
      focus)]))

(define (editor-area-panel-ids area)
  (layout-panel-ids (editor-area-layout area)))

(define (node-panel-count n)
  (cond
    [(not n) 0]
    [(leaf? n) 1]
    [else (+ (node-panel-count (split-left n))
             (node-panel-count (split-right n)))]))

(define (first-leaf-panel-id n)
  (cond
    [(not n) #f]
    [(leaf? n) (leaf-panel-id n)]
    [else (or (first-leaf-panel-id (split-left n))
              (first-leaf-panel-id (split-right n)))]))

(define (editor-area-first-panel-id area)
  (first-leaf-panel-id (layout-root (editor-area-layout area))))

(define (editor-area-panel-count state area-id)
  (cond
    [(equal? area-id (state-current-area state))
     (define slot (state-area-slot state))
     (define frame (state-layout state))
     (cond
       [(not frame) 0]
       [slot (node-panel-count (area-slot-child frame slot))]
       ;; 没有启用多 area（测试 / 旧 state）：按整个 layout 计数。
       [else (length (layout-panel-ids frame))])]
    [else
     (define area (hash-ref (state-areas state) area-id #f))
     (if area
         (node-panel-count (layout-root (editor-area-layout area)))
         0)]))

;;; ════════════════ area layout 写回 ════════════════

;; 当前 area 返回完整 frame（panel 就在 frame 里）；inactive 返回 editor-only layout。
(define (editor-layout-for-area state area-id)
  (cond
    [(equal? area-id (state-current-area state)) (state-layout state)]
    [else
     (define area (hash-ref (state-areas state) area-id #f))
     (and area (editor-area-layout area))]))

(define (editor-with-area-layout state area-id layout)
  (cond
    [(equal? area-id (state-current-area state))
     (state-with-layout state layout)]
    [else
     (define areas (state-areas state))
     (define area (hash-ref areas area-id #f))
     (cond
       [(not area) state]
       [else
        (state-with-areas
         state
         (hash-set areas area-id
                   (struct-copy editor-area area [layout layout])))])]))

;;; ════════════════ focus 校验 ════════════════

(define (focus-valid? state layout id)
  (define p (and id (layout-panel layout id)))
  (and p
       (p:panel-visible? p)
       (config-panel-focusable? (state-layout-config state)
                                (p:panel-kind p))))

(define (restore-focus state layout saved-focus area)
  (cond
    [(focus-valid? state layout saved-focus) saved-focus]
    [else
     (define pids (layout-panel-ids layout))
     (or (editor-area-first-panel-id area)
         (and (pair? pids) (car pids)))]))

;;; ════════════════ view 位置 ════════════════

;; 当前 frame + inactive areas 中查找 view 的唯一位置。
(define (editor-view-location state vid)
  (define current-id (state-current-area state))
  (define frame (state-layout state))
  (define pid (and frame vid (layout-panel-for-view frame vid)))
  (cond
    [pid (view-location current-id pid)]
    [else
     (for/or ([(area-id area) (in-hash (state-areas state))])
       (define area-pid (layout-panel-for-view (editor-area-layout area) vid))
       (and area-pid (view-location area-id area-pid)))]))

(define (editor-view-in-current-area? state vid)
  (define frame (state-layout state))
  (and frame vid (layout-panel-for-view frame vid) #t))

(define (editor-view-panel-id-in-area state area-id vid)
  (define l (editor-layout-for-area state area-id))
  (and l vid (layout-panel-for-view l vid)))

;;; ════════════════ 切换 ════════════════

;; 跨 area 的瞬时状态属于旧 frame：切换时清掉。
;; app-state 才有 session；editor-core 直接返回。
(define (clear-area-transients state)
  (cond
    [(not (app-state? state)) state]
    [else
     (state-with-select-drag
      (state-with-drag
       (state-clear-pending state)
       #f)
      #f)]))

;; 切换当前编辑区。纯 state 更新；不会创建 / 删除 engine view。
;; → state'
(define (editor-switch-area state target-id)
  (define current-id (state-current-area state))
  (define slot (state-area-slot state))
  (define frame (state-layout state))
  (cond
    [(or (not current-id) (not slot) (not frame)) state]
    [(equal? current-id target-id) state]
    [else
     (define current-area (editor-area-from-frame frame slot (layout-focus frame)))
     (define current-area-pids (editor-area-panel-ids current-area))
     (define old-areas (state-areas state))
     (define target-area
       (or (hash-ref old-areas target-id #f)
           (make-empty-editor-area target-id
                                   (layout-next-split-id frame))))
     (define target-layout (editor-area-layout target-area))
     (define target-root (layout-root target-layout))
     (unless target-root
       (error 'editor-switch-area "目标 area 没有 editor panel：~a" target-id))

     ;; 1. 替换 slot 子树。
     (define-values (new-root ok?)
       (area-slot-replace-child frame slot target-root))
     (unless ok?
       (error 'editor-switch-area "无法替换当前 frame 的 editor slot"))

     ;; 2. panel-map：去掉 current area，加入 target area。
     (define chrome-panels
       (for/hash ([pid (in-list (layout-panel-ids frame))]
                  #:unless (memv pid current-area-pids))
         (values pid (layout-panel frame pid))))
     (for ([pid (in-list (layout-panel-ids target-layout))])
       (when (hash-has-key? chrome-panels pid)
         (error 'editor-switch-area
                "area panel id 与 frame 中的 panel 冲突：~a" pid)))
     (define new-panels
       (for/fold ([h chrome-panels]) ([pid (in-list (layout-panel-ids target-layout))])
         (hash-set h pid (layout-panel target-layout pid))))

     ;; focus 校验必须使用“新 panel-map”的 frame。
     (define frame-new
       (make-layout #:root new-root
                    #:panels new-panels
                    #:focus (layout-focus frame)
                    #:next-split-id (layout-next-split-id target-layout)))
     (define new-focus
       (restore-focus state frame-new (editor-area-focus target-area) target-area))
     (define frame-final (struct-copy layout frame-new [focus new-focus]))

     ;; 3. current -> areas；target 从 areas 移除。
     (define new-areas
       (hash-set (if (hash-has-key? old-areas target-id)
                     (hash-remove old-areas target-id)
                     old-areas)
                 current-id
                 current-area))

     (define state-switched
       (state-with-current-area
        (state-with-areas
         (state-with-layout state frame-final)
         new-areas)
        target-id))

     ;; 4. 清理跨 area 的瞬时状态。
     (clear-area-transients state-switched)]))
