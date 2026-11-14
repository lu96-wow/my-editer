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
         area-slot-child
         area-slot-set-child

         make-empty-editor-area
         editor-area-from-frame
         editor-area-panel-ids
         editor-area-panel-count
         editor-area-first-panel-id
         area-editor-panel-id
         area-base-split-id

         editor-area-layout-for
         editor-with-area-layout
         editor-switch-area

         editor-view-location
         editor-view-in-current-area?
         editor-view-area
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

;; → (values layout' ok?)
(define (area-slot-set-child l slot child)
  (cond
    [(not slot) (values l #f)]
    [(not (area-slot-parent-id slot))
     (values (layout-with-root l child) #t)]
    [else
     (define parent-id (area-slot-parent-id slot))
     (define side (area-slot-side slot))
     (define-values (root* changed?)
       (update-split (layout-root l) parent-id
                     (λ (s)
                       (case side
                         [(left) (struct-copy split s [left child])]
                         [(right) (struct-copy split s [right child])]
                         [else
                          (error 'area-slot-set-child
                                 "area slot side 要是 left / right / root：~a"
                                 side)]))))
     (values (if changed?
                 (struct-copy layout l [root root*])
                 l)
             changed?)]))

;; 替换 root，保留 panel-map / focus / next-split-id。
(define (layout-with-root l root)
  (make-layout #:root root
               #:panels (layout-panel-map l)
               #:focus (layout-focus l)
               #:next-split-id (layout-next-split-id l)))


;;; ════════════════ 节点遍历 / 空 area ════════════════

(define (node-panel-ids n)
  (cond
    [(not n) '()]
    [(leaf? n) (list (leaf-panel-id n))]
    [else (append (node-panel-ids (split-left n))
                  (node-panel-ids (split-right n)))]))

(define (editor-panel-id-for-area area-id)
  (string->symbol (format "area-~a-editor" area-id)))

;; 默认第一个 area 使用 'editor，和 app/layout 的默认 editor panel 保持一致；
;; 其他 area 使用唯一 symbol，便于调试和跨 area 操作。
(define (area-editor-panel-id area-id)
  (if (equal? area-id 1)
      'editor
      (editor-panel-id-for-area area-id)))

;; 新 area 的 split-id 起点：必须避开 chrome 已用的 split-id。
(define (area-base-split-id layout)
  (layout-next-split-id layout))

(define (make-empty-editor-area area-id next-split-id [focus #f])
  (define pid (area-editor-panel-id area-id))
  (define panel
    (p:make-empty-editor-panel pid
                               #:borders '(up down left right)))
  (editor-area
   (make-layout #:root (make-leaf pid)
                #:panels (hash pid panel)
                #:focus pid
                #:next-split-id next-split-id)
   (or focus pid)))

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
     (define a (hash-ref (state-areas state) area-id #f))
     (if a
         (node-panel-count (layout-root (editor-area-layout a)))
         0)]))

;;; ════════════════ area layout 写回 ════════════════

;; 当前 area 返回完整 frame（panel 就在 frame 里）；inactive 返回 editor-only layout。
(define (editor-area-layout-for state area-id)
  (cond
    [(equal? area-id (state-current-area state)) (state-layout state)]
    [else
     (define a (hash-ref (state-areas state) area-id #f))
     (and a (editor-area-layout a))]))

(define (editor-with-area-layout state area-id layout)
  (cond
    [(equal? area-id (state-current-area state))
     (state-with-layout state layout)]
    [else
     (define areas (state-areas state))
     (define a (hash-ref areas area-id #f))
     (cond
       [(not a) state]
       [else
        (state-with-areas
         state
         (hash-set areas area-id
                   (struct-copy editor-area a [layout layout])))])]))

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
     (or (editor-area-first-panel-id area)
         (and (layout-panel-ids layout)
              (car (layout-panel-ids layout)))
         #f)]))

;;; ════════════════ view 位置 ════════════════

;; 当前 frame + inactive areas 中查找 view 的唯一位置。
(define (editor-view-location state vid)
  (define current-id (state-current-area state))
  (define frame (state-layout state))
  (define pid (and frame vid (layout-panel-for-view frame vid)))
  (cond
    [pid (view-location current-id pid)]
    [else
     (for*/first ([area-id (in-list (hash-keys (state-areas state)))]
                  [area (in-value (hash-ref (state-areas state) area-id #f))]
                  #:when area
                  [pid (in-value (layout-panel-for-view (editor-area-layout area) vid))]
                  #:when pid)
       (view-location area-id pid))]))

(define (editor-view-in-current-area? state vid)
  (define frame (state-layout state))
  (and frame vid (layout-panel-for-view frame vid) #t))

(define (editor-view-area state vid)
  (define loc (editor-view-location state vid))
  (and loc (view-location-area-id loc)))

(define (editor-view-panel-id-in-area state area-id vid)
  (define l (editor-area-layout-for state area-id))
  (and l vid (layout-panel-for-view l vid)))

;;; ════════════════ 切换 ════════════════

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
     (define current-pids (editor-area-panel-ids current-area))
     (define areas0 (state-areas state))
     (define target-area
       (or (hash-ref areas0 target-id #f)
           (make-empty-editor-area target-id
                                   (layout-next-split-id frame)
                                   (area-editor-panel-id target-id))))
     (define target-layout (editor-area-layout target-area))
     (define target-root (layout-root target-layout))
     (unless target-root
       (error 'editor-switch-area "目标 area 没有 editor panel：~a" target-id))

     ;; 1. 替换 slot 子树。
     (define-values (frame1 ok?)
       (area-slot-set-child frame slot target-root))
     (unless ok?
       (error 'editor-switch-area "无法替换当前 frame 的 editor slot"))

     ;; 2. panel-map：去掉 current area，加入 target area。
     (define chrome-panels
       (for/hash ([pid (in-list (layout-panel-ids frame))]
                  #:unless (memv pid current-pids))
         (values pid (layout-panel frame pid))))
     (for ([pid (in-list (layout-panel-ids target-layout))])
       (when (hash-has-key? chrome-panels pid)
         (error 'editor-switch-area
                "area panel id 与 frame 中的 panel 冲突：~a" pid)))
     (define panels*
       (for/fold ([h chrome-panels]) ([pid (in-list (layout-panel-ids target-layout))])
         (hash-set h pid (layout-panel target-layout pid))))

     ;; focus 校验必须使用“新 panel-map”的 frame；frame1 还是旧 panel-map。
     (define frame0
       (make-layout #:root (layout-root frame1)
                    #:panels panels*
                    #:focus (layout-focus frame)
                    #:next-split-id (layout-next-split-id target-layout)))
     (define focus* (restore-focus state frame0 (editor-area-focus target-area) target-area))
     (define frame* (struct-copy layout frame0 [focus focus*]))

     ;; 3. current -> areas；target 从 areas 移除。
     (define areas*
       (hash-set (if (hash-has-key? areas0 target-id)
                     (hash-remove areas0 target-id)
                     areas0)
                 current-id
                 current-area))

     (define state*
       (state-with-current-area
        (state-with-areas
         (state-with-layout state frame*)
         areas*)
        target-id))

     ;; 4. 清理跨 area 的瞬时状态。app-state 才有 session。
     (if (app-state? state*)
         (state-with-select-drag
          (state-with-drag
           (state-clear-pending state*)
           #f)
          #f)
         state*)]))
