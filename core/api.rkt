#lang racket

;;; ============================================================================
;;; api.rkt —— core 层对外的唯一入口
;;; ============================================================================
;;;
;;; 一个纯函数式的编辑器核心：只有「底层数据原子 + 它们的纯函数变换」。
;;; 不含多窗口组合 / 布局 / 命令 / 插件 / 后端。所有结构 #:transparent、不可变。
;;;
;;; ── 唯一约定 ────────────────────────────────────────────────
;;;   使用方一律 (require "core/api.rkt")，
;;;   不要直接 require core/text/* 或 core/view/*。
;;;   内部模块按依赖互相 require，是「实现细节」，外部不接触。
;;;
;;; ── 最小原子（组合出一个编辑器只需要这些）──────────────────────
;;;
;;;   【数据：来回传的「东西」】
;;;   buffer      文档：文本 + 属性 + 标记 + 装饰（无光标）
;;;   events      输入：text/key/mouse/resize/quit（后端喂进来）
;;;   screen      输出：一帧画面（每行几段 run + 一个光标，交给后端画）
;;;
;;;   【操作：真正的「API」只有这两个】
;;;   window      视口（**纯视图**）：buffer 引用 + 光标 + 滚动 + 尺寸
;;;               · 导航：window-goto/left/right/up/down/home/end + window-visual-move
;;;               · 状态：window-set-* / window-scroll / window-ensure-point
;;;               （**不编辑** —— 编辑改共享 buffer，属于 document）
;;;   window->screen  投影：window 可见区 → screen（纯函数，无副作用）
;;;
;;; ── 两条数据流 ──────────────────────────────────────────────
;;;
;;;   编辑流：
;;;     events → document-edit（唯一编辑入口，收 edit-fn：edit-*）→ buffer-* → 新 buffer + edit-change
;;;     （入口自动换新 buffer、把光标推到编辑后位置，并 rebase 其余视图）
;;;
;;;   渲染流：
;;;     buffer → render-line → glyph → line-range->runs → run
;;;            → window->screen → screen → 后端画出来
;;;
;;; ── 属性怎么参与（关键）──────────────────────────────────────
;;;   属性不是和 screen 拼的，是「存在 buffer 里」的：
;;;
;;;     buffer-put-property b 0 1 7 'face 'keyword          ; 裸 buffer 上写
;;;     document-put-properties-many doc segs                ; 活文档上写（不丢视图）
;;;       │  编辑时 properties-apply-edit 让属性跟着文本自动移动
;;;       ▼
;;;     window->screen 投影时，render-line 把该位置的属性读出来
;;;       │  变成 glyph 的 face
;;;       ▼
;;;     screen 里的 run.face = (hash 'face 'keyword)
;;;       │  后端 (hash-ref (run-face r) 'face) → 主题 → 颜色
;;;       ▼
;;;     终端显示蓝色
;;;
;;;   裸 buffer 用 buffer-put-property / buffer-put-properties-many；
;;;   活文档（有视图）用 document-put-properties-many / document-update-buffer。
;;;   之后全是自动的。
;;;
;;; ── read-only 区域（显示 + 输入）──────────────────────────────
;;;   read-only 是**约束槽**（restrict，typed），不是表现层属性：
;;;   (buffer-put-restrict b 0 0 2 (restrict #t))  ; "> " 不可编辑
;;;   编辑在 splice 层被拦截；且它是「硬边界」：边界插入什么都不继承。
;;;   约束不进 screen 的 face；配色另写表现层键（如 'face 'prompt）。
;;;   程序要编辑 read-only 内容：走显式入口 buffer-splice-trusted（无全局开关）。
;;;
;;;     (buffer-put-restrict b 0 0 2 (restrict #t))    ; "> " 不可编辑
;;;     ;; 光标放输入区，打字只落在可编辑处；backspace 到边界就删不动
;;;
;;; ── 最小编辑器骨架 ──────────────────────────────────────────
;;;
;;;   (define-values (doc _) (document-add-view (document-open "hello") 24 80))  ; 开文档 + 开视口
;;;   (define s (window->screen (document-window doc 0)))   ; 投影成画面
;;;   ;; 后端画 s；后端喂入一个 event：
;;;   (define-values (doc* ch) (document-edit doc 0 (edit-insert-char #\X)))  ; 处理 text-event
;;;   ;; doc* 的 buffer 已换新、光标已推进；ch 是 (or/c #f edit-change)，
;;;   ;; #f = 什么都没发生，非 #f 时上层拿它做记账（要撤销就收下 ch）
;;;
;;; ── 唯一跨层契约 ────────────────────────────────────────────
;;;   edit-desc   (s-line s-col e-line e-col new-text)
;;;   一次编辑 = 删除 [s..e) + 插入 new-text（所有编辑都是它的特例）。
;;;   edit-change (desc inv pre-point)
;;;   一次编辑的**完整材料**：desc（重放用）+ inv（撤销用，从编辑前的 buffer 导出）
;;;   + pre-point（编辑前光标）。缓冲区层没有光标，故只有 document-edit 产出它。
;;;
;;;   编辑入口返回 (values 新值 (or/c #f edit-change))，没发生就是 #f；
;;;   导航/状态原语直接返回新值。
;;;
;;; ── 导出边界：**显式白名单**（ARCHITECTURE §8.8）────────────────────
;;; 对外名字**逐个列出**：新增内部函数**不会**自动泄漏（原来是 `except-out all-from-out`，
;;; fail-open —— 加个内部助手就默认对外）。白名单与 MANUAL 的「消费者 API」栏目一一对应，
;;; 可用 `tools/reconcile.rkt` 对账。
;;;   对外（消费者层）：point buffer window screen events edit-desc edit-change patch width document
;;;   对外（机制层）：buffer-splice / buffer-splice-trusted / buffer-apply-edit-batch、
;;;                buffer-apply-edit(-trusted)、buffer-edit-desc-inverse / edit-desc-inverse、
;;;                marker/overlay 的 buffer 级入口、edit-change、restrict / make-restrict、
;;;                document-apply-descs-trusted / document-update-buffer
;;;   藏起来（内部实现）：content-* properties-* marker-table-* overlay-table-* view
;;;                     render-* vrow/layout/wrap/window-vrows、check-mode、snap-left-col
;;; ============================================================================

(require "text/point.rkt"
         "text/content.rkt"
         "text/buffer.rkt"
         "text/edit.rkt"
         "text/patch.rkt"
         "view/events.rkt"
         "view/width.rkt"
         "view/screen.rkt"
         "view/window.rkt"
         "view/view.rkt"
         "view/project.rkt"
         "view/document.rkt")

(provide
 ;; ---- 消费者层（显式白名单）----
 ;; point —— 位置 (line,col)
 point point-clamp point-col point-line point<=? point<? point=? point? pos<? pos=? struct:point
 ;; edit-desc —— 唯一跨层契约（文本存储本身是内部实现）
 edit-desc edit-desc? struct:edit-desc edit-desc-s-line edit-desc-s-col
 edit-desc-e-line edit-desc-e-col edit-desc-new-text edit-desc-after-position
 edit-desc-map-position edit-desc-inverse
 ;; edit-change —— 一次编辑的完整材料（新 document + 它，就是编辑入口的全部产出）
 edit-change edit-change? struct:edit-change
 edit-change-desc edit-change-inv edit-change-pre-point
 ;; buffer —— 文档原子（装配根）
 buffer buffer? struct:buffer buffer-open buffer->string buffer->lines
 buffer-line-count buffer-line-ref
 buffer-splice buffer-splice-trusted buffer-insert-char buffer-insert-string
 buffer-newline buffer-backspace buffer-delete
 edit-insert-char edit-insert edit-newline edit-backspace edit-delete edit-splice
 buffer-apply-edit buffer-apply-edit-trusted buffer-edit-desc-inverse
 buffer-put-property buffer-get-property buffer-remove-property buffer-put-properties-many
 buffer-put-restrict buffer-read-only-at? buffer-restrict-runs
 restrict restrict? struct:restrict make-restrict restrict-read-only?
 buffer-add-marker buffer-remove-marker buffer-marker-pos
 buffer-add-overlay buffer-remove-overlay
 ;; 装配层访问器（一般用不到）
 buffer-content buffer-properties buffer-markers buffer-overlays
 buffer-tick buffer-modified? buffer-gap
 ;; 批量编辑应用 + 点映射 / 行区间（机制）
 buffer-apply-edit-batch edits-map-position edits-span
 ;; patch —— 补丁 delta（机制）
 patch patch? struct:patch patch-key patch-first-line patch-last-line patch-segs
 buffer-apply-patches buffer-content-eq?
 ;; ---- 视口层 ----
 ;; 类型化输入事件
 modifiers modifiers? struct:modifiers
 modifiers-control modifiers-alt modifiers-shift modifiers-meta
 text-event text-event? struct:text-event text-event-text text-event-modifiers
 key-event key-event? struct:key-event key-event-key key-event-modifiers
 mouse-press-event mouse-press-event? struct:mouse-press-event
 mouse-press-event-button mouse-press-event-x mouse-press-event-y mouse-press-event-modifiers
 mouse-wheel-event mouse-wheel-event? struct:mouse-wheel-event
 mouse-wheel-event-direction mouse-wheel-event-x mouse-wheel-event-y mouse-wheel-event-modifiers
 resize-event resize-event? struct:resize-event resize-event-rows resize-event-cols
 quit-event quit-event? struct:quit-event
 ;; 字符 ↔ 显示列（宽字符宽度，供上层截断/量宽）
 char-display-width string-display-width index->column column->index snap-column-forward
 ;; screen —— 输出契约
 screen screen? struct:screen screen-rows screen-cols screen-row-runs
 screen-cursor-row screen-cursor-col
 make-screen screen-diff-rows screen-compose screen->text
 run run? struct:run run-col run-text run-face
 ;; window —— 视口（纯视图）+ 导航
 window window? struct:window window-open window-buffer window-point
 window-height window-width window-mode window-top-line window-left-col window-top-seg
 window-set-buffer window-set-point window-set-mode window-set-top window-set-left
 window-set-top-seg window-set-size window-scroll window-hscroll window-goto
 window-left window-right window-home window-end
 ;; 窗口级操作（vrow 布局内部藏起来）
 window-ensure-point window-clamp-view window-visual-move window-up window-down
 window-point->screen window-screen->point window-scroll-visual
 ;; window->screen —— 投影成画面
 window->screen
 ;; document —— 共享 buffer 的多窗口同步（唯一编辑入口 + 装饰写回）
 document document? struct:document document-open document-of-buffer
 document->string document->lines document-line-count document-line-ref
 document-get-property document-read-only-at? document-restrict-runs
 document-add-view document-view-count document-window
 document-view-sync document-set-view-sync document-update-view
 document-sync-followers
 document-update-buffer document-put-property document-put-properties-many
 document-remove-property document-put-restrict document-apply-patches
 document-edit document-apply-descs-trusted
 document-buffer)

;;; ============================================================================
;;; 冒烟测试：验证门面 + 一条完整的「属性 → 画面」链
;;; ============================================================================

(module+ test
  (require rackunit)

  ;; 门面转发后，核心绑定可用
  (define b (buffer-open "hello\nworld"))
  (check-equal? (buffer->string b) "hello\nworld")
  (check-equal? (buffer-line-count b) 2)

  ;; 编辑闭环：document-edit（唯一编辑入口）→ 光标推进 → 渲染出新文本
  (define-values (d0 _i0) (document-add-view (document-open (buffer->string b)) 2 10))
  (check-equal? (window-point (document-window d0 0)) (point 0 0))
  (define-values (d1 ch) (document-edit d0 0 (edit-insert-char #\X)))
  (check-equal? (document->string d1) "Xhello\nworld")
  (check-equal? (edit-change-desc ch) (edit-desc 0 0 0 0 "X"))
  (check-equal? (window-point (document-window d1 0)) (point 0 1))
  (check-equal? (screen-rows (window->screen (document-window d1 0))) 2)

  ;; 属性链：写进 buffer → 自动流进 screen 的 run.face
  (define b3 (buffer-put-property b 0 0 5 'face 'keyword))
  (define s3 (window->screen (window-open b3 2 10)))
  (define row0 (vector-ref (screen-row-runs s3) 0))
  (check-equal? (car row0) (run 0 "hello" (hash 'face 'keyword)))

  ;; 属性随编辑移动：在属性区间前插一个字符 → 区间整体右移。
  ;; 插入点在左邻为空处，新字符不继承（继承左邻规则）；"hello" 仍带 keyword。
  (define-values (d3 _d3i) (document-add-view (document-of-buffer b3) 2 10))
  (define-values (d4 _) (document-edit d3 0 (edit-insert-char #\Z)))
  (define s4 (window->screen (document-window d4 0)))
  (check-equal? (vector-ref (screen-row-runs s4) 0)
                (list (run 0 "Z" (hash))
                      (run 1 "hello" (hash 'face 'keyword))))

  (displayln "api.rkt: all tests passed"))
