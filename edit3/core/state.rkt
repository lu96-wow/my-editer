#lang racket

;;; edit3/core/state.rkt —— State + 值类型（布局重构版）
;;;
;;; 布局子项不是固定格数，而是求解器的输入 basis/grow/shrink/min（见 layout.rkt）。
;;; 平铺树只描述「结构 + 弹性意图」，几何永不存；浮窗不进平铺树，是覆盖层。
;;;
;;; ed   ：core 编辑器句柄（命令式引擎，box 是设计；线性穿过，不进 State 语义）
;;; docs ：did -> doc-meta（路径 / 存档句柄），文本真身在 core
;;; views：feature 局部状态（feature-ref / feature-set）

(provide
 (struct-out rect) (struct-out anchor)
 (struct-out tile) (struct-out float)
 editor-tile panel-tile
 (struct-out item) (struct-out split) (struct-out tiling)
 (struct-out placement) (struct-out handle) (struct-out geometry)
 (struct-out idle) (struct-out dragging)
 (struct-out doc-meta)
 (struct-out prompt)
 (struct-out placing)
 (struct-out state)
 make-state feature-ref feature-set)

(struct rect (x y w h) #:transparent)

;; 浮窗锚点：rel = 'screen | wid；h/v 决定贴哪条边；dx/dy 偏移。
(struct anchor (rel h v dx dy) #:transparent)

;; ---- 平铺容器树 ----
;; tile  = 叶子：一个窗口（wid 显示 vid）；min = (cons min-w min-h) 该叶子的硬下限。
;;         编辑窗用 (editor-tile …)（2×2），面板/单行条用 (panel-tile …)（1×1）。
;; item  = split 的一段：basis 基准格数，grow/shrink 分配权重（0 = 固定），min 沿轴硬下限
;; split = 行列容器；tiling = 根（root 可为 #f）
(struct tile  (wid vid min) #:transparent)
(define (editor-tile wid vid) (tile wid vid (cons 2 2)))
(define (panel-tile wid vid)  (tile wid vid (cons 1 1)))
(struct item  (basis grow shrink min child) #:transparent)
(struct split (axis items) #:transparent)            ; axis : 'h | 'v
(struct tiling (root) #:transparent)

;; ---- 浮窗：不在平铺树里；顺序 = z（表头最上）。size = (cons w h) ----
(struct float (wid vid anchor size) #:transparent)

;; ---- 求解结果：几何带来源 ----
(struct placement (wid vid rect z) #:transparent)
(struct handle    (kind rect z data) #:transparent)  ; kind : 'boundary | 'float-move | 'float-resize-*
(struct geometry  (placements handles w h) #:transparent)

;; ---- 指针交互 ----
(struct idle     () #:transparent)
(struct dragging (handle start-x start-y snapshot) #:transparent)

;; doc-meta：path = 文件路径 | #f（无文件名）；saved = 存档时的 core document 句柄。
(struct doc-meta (path saved) #:transparent)

;; 输入行（数据化：kind 决定提交时的行为）；存在 feature 'prompt。
;; 正文在 *input* 文档；打开时把状态栏 pane 的 vid 换成 *input*。
(struct prompt (wid label kind data prev-focus) #:transparent)

;; 放置选择（打开时多窗口 → 用户选目标窗格）；存在 feature 'placing。
(struct placing (vid prev-focus) #:transparent)

;; ---- 唯一状态 ----
;; ed = core 编辑器句柄（命令式引擎）；docs/views 为元数据。
(struct state (ed docs views tiling floats focus drag) #:transparent)

(define (make-state #:ed     [ed #f]
                    #:docs   [docs (hash)]
                    #:views  [views (hash)]
                    #:tiling [t (tiling #f)]
                    #:floats [f '()]
                    #:focus  [fo #f]
                    #:drag   [d (idle)])
  (state ed docs views t f fo d))

;;; ---------- 特性局部状态（存在 views 里，不新增全局字段） ----------

(define (feature-ref st k d) (hash-ref (state-views st) k d))
(define (feature-set st k v)
  (struct-copy state st [views (hash-set (state-views st) k v)]))
