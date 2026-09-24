#lang racket

;;; api-temp/api/3-render.rkt —— 底层原理 · 渲染
;;;
;;; 只讲低层公开面 + 必要的子模块（core/api.rkt 门面故意很窄）：
;;;   core/api.rkt              门面：window 读口 + screen 读口 / damage / compose + mirror + window->screen
;;;   core/viewport/layout.rkt  视觉行 vrow、wrap-segments、layout-clip/wrap、window-vrows、line-range->runs
;;;   core/viewport/render.rkt  单行 glyph：render-line / glyph / rendered-line / empty-face-provider
;;;   core/unit/screen.rkt      screen 构造器（门面只给读口/合成，不给构造器）
;;; editor 层的投影在 api-temp/editor/3-render.rkt。
;;;
;;; 渲染分四步（每步都可单独测、可替换）：
;;;   ① window  ——「怎么看」：选区/滚动/尺寸/模式（与 document 分开）
;;;   ② vrow    ——把可见区摊成「视觉行」（clip 不折行 / wrap 折行）
;;;   ③ render  ——一行文本 + 派生 face → glyph 向量
;;;   ④ screen  ——纯语义的帧（文本 runs + 光标/选区 overlay），后端负责画字节
;;;
;;; 运行：racket api-temp/api/3-render.rkt

(require "../../core/api.rkt"
         "../../core/viewport/layout.rkt"   ; vrow / wrap-segments / layout-* / window-vrows / line-range->runs
         "../../core/viewport/render.rkt"   ; render-line / glyph / rendered-line / empty-face-provider
         "../../core/unit/screen.rkt")      ; screen 构造器

(define (show label v) (printf "~a\n    => ~v\n" label v))
(define (header s) (printf "\n========== ~a ==========\n" s))
(define (P l c) (point l c))

;;; ===========================================================================
(header "1. width —— 显示宽度（wcwidth 语义；终端宽字符占 2 列）")
;;; ===========================================================================

;; 设计：point.col 是**字符索引**，但屏幕是按**显示列**排的；两者在宽字符/组合字符上不同。
;;   这里只做几何换算，不依赖 locale（查 Unicode 表）；tab 按 1 计（要展开是使用方的事）。
;; 用法：任何「字符索引 ↔ 屏幕列」的换算都过这一层，别自己用 string-length。
(show "(char-display-width #\\a / #\\中 / 组合字符)" (list (char-display-width #\a)
                                                          (char-display-width #\中)
                                                          (char-display-width (integer->char #x0301))))
(show "(string-display-width \"a中b\")" (string-display-width "a中b"))
;; index->column : string nat → nat（字符索引 → 显示列；i=长度 → 总列数）
(show "(index->column \"a中b\" 2)" (index->column "a中b" 2))
;; column->index : string nat → nat（显示列 → 字符索引；宽字符右半格命中同一字符）
(show "(column->index \"a中b\" 2)" (column->index "a中b" 2))
;; snap-column-forward : string nat → nat（把显示列吸附到字符起点，避免画出半格）
(show "(snap-column-forward \"中a中\" 1)" (snap-column-forward "中a中" 1))

;;; ===========================================================================
(header "2. window —— 视口（看哪个 document + 自己的选区/滚动/尺寸）")
;;; ===========================================================================

;; 设计：document 是「内容」，window 是「怎么看」。分区很清楚：
;;   · 光标/选区、滚动位置、尺寸、clip/wrap 都在 window 上 —— 同一文档开两个 window 就是分屏，
;;     各有独立光标，互不干扰；
;;   · window 只**引用** document，不改它；换文档走 window-set-document（会自动夹选区）。
;; 用法：一切「视图态」操作在这里；编辑永远不在这里。

;; window-open : document [nat nat] → window（收的是 **document**，不是 buffer）
(define d (document-open "hello\nworld"))
(define w0 (window-open d 2 10))
(show "(window-buffer w0) = (document-buffer d)? " (eq? (window-buffer w0) (document-buffer d)))
(show "(window-document w0) = d? " (eq? (window-document w0) d))
(show "(window-height w0) (window-width w0)" (list (window-height w0) (window-width w0)))
(show "(window-mode w0)" (window-mode w0))
(show "(window-point w0)" (window-point w0))
(show "(window-selections w0)" (window-selections w0))
(show "(window-primary w0)" (window-primary w0))
(show "(window-primary-index w0)" (window-primary-index w0))
(show "(window-selection-set-name w0)" (window-selection-set-name w0))
(show "(window-top-line w0) (window-left-col w0) (window-top-seg w0)"
      (list (window-top-line w0) (window-left-col w0) (window-top-seg w0)))
(show "(window-line-numbers? w0)" (window-line-numbers? w0))

;; window-set-document : window document → window
;;   设计：换属主（不触发同步、不动文本）；选区被夹到新文档合法域。
(show "(window-set-document w0 \"NEW\\nDOC\") → buffer string"
      (buffer->string (window-buffer (window-set-document w0 (document-open "NEW\nDOC")))))

;; 尺寸 / 模式 / 视口
(show "(window-set-size w0 3 5) → h w"
      (let ([w (window-set-size w0 3 5)]) (list (window-height w) (window-width w))))
(show "(window-set-mode w0 'wrap)" (window-mode (window-set-mode w0 'wrap)))
(show "(window-set-top-line w0 1)" (window-top-line (window-set-top-line w0 1)))
(show "(window-set-left-col w0 3)" (window-left-col (window-set-left-col w0 3)))
(show "(window-set-top-seg (wrap w0) 1)" (window-top-seg (window-set-top-seg (window-set-mode w0 'wrap) 1)))
(show "(window-set-line-numbers w0 #t)" (window-line-numbers? (window-set-line-numbers w0 #t)))
;; vscroll/hscroll 只加减，不夹紧（夹紧是 window-clamp-view 的事，见 §3）
(show "(window-vscroll w0 1) / (window-hscroll w0 2)"
      (let ([w (window-hscroll (window-vscroll w0 1) 2)]) (list (window-top-line w) (window-left-col w))))

;; 光标 / 选区：都在 window 上，所以一个文档的多个 window 各自独立。
(show "(window-set-point w0 (point 1 3)) → point" (window-point (window-set-point w0 (P 1 3))))
(define ws (window-set-selections w0 (list (selection (P 0 1) (P 0 4)) (caret (P 1 2))) 1))
(show "(window-set-selections [sel caret] primary=1)" (window-selections ws))
(show "(window-primary ws)" (window-primary ws))
(show "(window-add-selection ws (caret (0,5))) count"
      (length (window-selections (window-add-selection ws (caret (P 0 5))))))
(show "(window-add-selection ws ... #:primary? #t) → primary"
      (window-primary (window-add-selection ws (caret (P 0 5)) #:primary? #t)))
(show "(window-remove-selection ws (caret (1,2))) count"
      (length (window-selections (window-remove-selection ws (caret (P 1 2))))))
(show "(window-set-primary ws [0,1)-(0,4))" (window-primary (window-set-primary ws (selection (P 0 1) (P 0 4)))))
(show "(window-set-primary-index ws 0)" (window-primary-index (window-set-primary-index ws 0)))
(show "(window-selection-member? ws (caret (0,1)))" (window-selection-member? ws (caret (P 0 1))))
(show "(window-map-points ws 右移) → heads"
      (map selection-head (window-selections (window-map-points ws (lambda (p) (point-right (window-buffer ws) p))))))
(show "(window-map-primary ws 坍缩到 anchor) → primary"
      (window-primary (window-map-primary ws (lambda (s) (caret (selection-anchor s))))))
(show "(window-map-selections ws 两端同移) → sels"
      (window-selections (window-map-selections ws (lambda (s) (selection-map-both (lambda (p) p) s)))))
(show "(window-put-selection-set / window-clear-selection-set)"
      (let* ([g (selection-set-open 'grp (list (caret (P 0 0)) (caret (P 0 3))) 0)]
             [w (window-put-selection-set w0 g)])
        (list (window-selection-set-name w)
              (window-selection-set-name (window-clear-selection-set w)))))
(show "(window-clamp-selections ws 后)" (window-selections (window-clamp-selections ws)))

;; 点运动（纯点算子，不认识视口）：buffer 提供文本几何，所以收 buffer。
(define b (window-buffer w0))
(show "(point-left b (1,0))" (point-left b (P 1 0)))
(show "(point-right b (0,5))" (point-right b (P 0 5)))
(show "(point-home (1,3))" (point-home (P 1 3)))
(show "(point-end b (0,0))" (point-end b (P 0 0)))
;; window-left/right/home/end : window → window（对每个选区坍缩后移动；与点算子互补）
(show "(window-right w0) → point" (window-point (window-right w0)))
(show "(window-end w0) → point" (window-point (window-end w0)))
;; 注：window.rkt 的 snap-left-col / check-mode 不在 core/api.rkt 门面里；
;;     显示列吸附用 width 层的 snap-column-forward（见 §1）。

;;; ===========================================================================
(header "3. layout —— 视觉行（vrow）/ 折行 / 光标映射 / 滚动")
;;; ===========================================================================

;; 设计：把「可见区」抽象成 vrow 序列（视觉行），clip 与 wrap 只是**生成方式不同**，
;;   之后的渲染、光标/鼠标映射、滚动完全共用同一套。列一律是**显示列**。
;;   clip：一条 buffer 行 = 一条 vrow，列范围 [left-col, left-col+width)；
;;   wrap：一条 buffer 行 = 若干段，每段 ≤ width，宽字符绝不切半。

;; wrap-segments : string nat → (listof (cons start-col end-col))
(show "(wrap-segments \"abcdefgh\" 3)" (wrap-segments "abcdefgh" 3))
(show "(wrap-segments \"中中中\" 4)" (wrap-segments "中中中" 4))

;; vrow : nat nat nat → vrow（line = buffer 行号，-1 = 空白行）
(show "(vrow 0 0 4)" (vrow 0 0 4))
(show "(vrow-line / -start-col / -end-col)" (list (vrow-line (vrow 0 0 4))
                                                  (vrow-start-col (vrow 0 0 4))
                                                  (vrow-end-col (vrow 0 0 4))))

;; layout-clip : buffer nat nat nat nat → (vectorof vrow)（top-line left-col width height）
(show "(layout-clip b 0 0 5 2)"
      (for/list ([vr (in-vector (layout-clip b 0 0 5 2))]) (list (vrow-line vr) (vrow-start-col vr) (vrow-end-col vr))))
;; layout-wrap : buffer nat nat nat nat → (vectorof vrow)（top-line top-seg width height）
(define bw (buffer-open "abcdefgh"))
(show "(layout-wrap bw 0 0 3 3)"
      (for/list ([vr (in-vector (layout-wrap bw 0 0 3 3))]) (list (vrow-line vr) (vrow-start-col vr) (vrow-end-col vr))))
;; window-vrows : window → (vectorof vrow)（按 window 的 mode 选 clip/wrap）
(show "(window-vrows clip w0)"
      (for/list ([vr (in-vector (window-vrows w0))]) (list (vrow-line vr) (vrow-start-col vr) (vrow-end-col vr))))

;; window-gutter-width / window-content-width : window → nat
;;   设计：行号栏宽度从「行号上界位数」现算（不存），正文宽 = 总宽 - 栏宽。
(show "(gutter / content) 关行号" (list (window-gutter-width w0) (window-content-width w0)))
(show "(gutter / content) 开行号"
      (let ([w (window-set-line-numbers w0 #t)]) (list (window-gutter-width w) (window-content-width w))))

;; window-point->screen : window [point] → (values row col)（不可见 → (values #f #f)）
;;   设计：point（字符索引）→ 视口内屏幕坐标（显示列，含折行/滚动/行号栏）。
(show "(window-point->screen w0 (point 0 0))" (call-with-values (lambda () (window-point->screen w0 (P 0 0))) list))
(show "(window-point->screen w0 (point 1 3))" (call-with-values (lambda () (window-point->screen w0 (P 1 3))) list))
;; 不可见 ≠ 越界：先滚屏，再投一个不在视口内的合法位置
(define wscroll (window-set-top-line (window-open (document-open "l0\nl1\nl2\nl3\nl4") 2 10) 3))
(show "(window-point->screen 滚动后 (point 0 0) 不可见)"
      (call-with-values (lambda () (window-point->screen wscroll (P 0 0))) list))
;; window-screen->point : window nat nat → (values line col)（越界 → (values #f #f)；行号栏列归行首）
(show "(window-screen->point w0 1 2)" (call-with-values (lambda () (window-screen->point w0 1 2)) list))
(show "(window-screen->point 行越界 9 0)" (call-with-values (lambda () (window-screen->point w0 9 0)) list))

;; window-scroll : window nat → window（clip 滚行 / wrap 滚视觉行；夹紧靠 window-clamp-view）
(define wscroll2 (window-open (document-open "l0\nl1\nl2\nl3") 2 10))
(show "(window-scroll wscroll2 1) → top-line" (window-top-line (window-scroll wscroll2 1)))
;; window-ensure-point : window → window（把光标挪进可见区，滚动/导航后保持可见）
(define wfar (window-set-point (window-open (document-open "0\n1\n2\n3\n4\n5") 3 10) (P 5 0)))
(show "(window-ensure-point wfar) → top-line" (window-top-line (window-ensure-point wfar)))
;; window-clamp-view : window → window（top/left 夹回合法域；free 视图「钉住但仍在域内」）
(show "(window-clamp-view 越界 top) → top-line"
      (window-top-line (window-clamp-view (window-set-top-line w0 99))))
;; 视觉行移动：上/下按**视觉行**（wrap 下是折行段），保持视觉列
(define wm (window-open (document-open "l0\nl1\nl2") 3 10))
(show "(point-down wm (point 0 0))" (point-down wm (P 0 0)))
(show "(point-up wm (point 2 0))" (point-up wm (P 2 0)))
(show "(window-down wm) → point" (window-point (window-down wm)))
(show "(window-visual-move wm 1) → point" (window-point (window-visual-move wm 1)))

;; line-range->runs : buffer nat nat nat [provider] → (listof run)
;;   设计：把一行的 [start,end) 显示列切成 runs；provider 给派生 face。
(show "(line-range->runs b 0 0 5)" (line-range->runs b 0 0 5))
(show "(line-range->runs b 0 1 3)" (line-range->runs b 0 1 3))

;;; ===========================================================================
(header "4. render —— 单行：buffer 一行 → glyph 向量（face 来自 provider）")
;;; ===========================================================================

;; 设计：face **不存文档**，全部来自投影参数。派生 face（如语法高亮）= content 的纯函数，
;;   随投影现算 → 不会过期、无需失效。provider : buffer line → (list (start end face))。
;; 用法：想要高亮就传 provider；不传 = 无 face。

;; empty-face-provider : buffer line → '()（缺省：无派生 face）
(show "(empty-face-provider b 0)" (empty-face-provider b 0))

;; render-line : buffer nat [provider] → rendered-line
(define rl (render-line b 0))
(show "(rendered-line? rl)" (rendered-line? rl))
(show "(rendered-line-glyphs rl) 长度" (vector-length (rendered-line-glyphs rl)))
(show "(glyph-ch / glyph-face 头两个)"
      (let ([g0 (vector-ref (rendered-line-glyphs rl) 0)])
        (list (glyph-ch g0) (glyph-face g0))))

(define (hl-provider _b line)
  (if (zero? line) (list (list 0 5 (hash 'face 'keyword))) '()))
(show "(render-line b 0 hl-provider) 头两个 glyph face"
      (let ([g (rendered-line-glyphs (render-line b 0 hl-provider))])
        (list (glyph-face (vector-ref g 0)) (glyph-face (vector-ref g 4)))))

;;; ===========================================================================
(header "5. screen —— 后端无关的帧（文本 runs + 光标/选区 overlay）")
;;; ===========================================================================

;; 设计：screen 有**两条独立通道**：
;;   ① row-runs —— 文档文本 + 派生 face（文档/投影产物）；
;;   ② cursors / selections —— 视图 overlay（临时，活跃窗格才有光标）。
;;   face 是**不透明语义值**（core 不解释、更不给颜色）：后端把它映射成样式。
;; 用法：后端只读 screen-row / screen-cursors / screen-selections；核心不认终端。

;; run : nat string any/c → run（col 是**显示列**，0-based）
(show "(run 0 \"hello\" (hash 'face 'bold))" (run 0 "hello" (hash 'face 'bold)))
;; cursor : nat nat any/c boolean → cursor（primary?）
(show "(cursor 1 2 (hash 'face 'cursor) #t)" (cursor 1 2 (hash 'face 'cursor) #t))
;; region : nat nat nat any/c → region（row, [start,end) 显示列）
(show "(region 0 1 4 (hash 'face 'selection))" (region 0 1 4 (hash 'face 'selection)))
;; pane : symbol nat nat screen → pane（x/y = 左上角；可负，超出裁掉）
(define mini (screen-empty 2 4))
(show "(pane 'left 0 0 mini)" (pane 'left 0 0 mini))

;; screen : nat nat (vectorof (listof run)) (listof cursor) (listof region) → screen
(define scr (screen 2 10
                    (vector (list (run 0 "hello" #f)) (list (run 0 "world" (hash 'face 'x))))
                    (list (cursor 1 3 (hash 'face 'cursor) #t))
                    (list (region 0 0 5 (hash 'face 'selection)))))
(show "(screen? scr)" (screen? scr))
(show "(screen-height / screen-width)" (list (screen-height scr) (screen-width scr)))
(show "(screen-row scr 0)" (screen-row scr 0))
(show "(screen->rows scr)" (screen->rows scr))
(show "(screen-row->string scr 0)" (screen-row->string scr 0))
(show "(screen->string scr)" (screen->string scr))
(show "(screen-cursors scr)" (screen-cursors scr))
(show "(screen-selections scr)" (screen-selections scr))
(show "(screen-cursor-row / -col)" (list (screen-cursor-row scr) (screen-cursor-col scr)))
(show "(screen-primary-cursor scr)" (screen-primary-cursor scr))

;; screen-empty : nat nat → screen
(show "(screen-empty 2 3)" (screen-empty 2 3))

;; screen-damage : screen screen → (or/c (listof nat) #f)
;;   设计：增量重绘——只给「需要整行重画」的行（文本 runs 或 overlay 变了）；
;;         #f = 尺寸变了，必须整屏重画。
(define scr2 (screen 2 10
                     (vector (list (run 0 "hello" #f)) (list (run 0 "WORLD" #f)))
                     '() '()))
(show "(screen-damage scr scr2)" (screen-damage scr scr2))
(show "(screen-damage 尺寸变 → #f)" (screen-damage scr (screen-empty 3 10)))

;; screen-compose : nat nat (listof pane) symbol → screen
;;   设计：拼屏只做几何平移；**只有 active pane 的光标**透出（非活动窗格不显示光标）。
(define left  (screen 1 3 (vector (list (run 0 "abc" #f))) (list (cursor 0 1 (hash 'face 'cursor) #t)) '()))
(define right (screen 1 3 (vector (list (run 0 "XYZ" #f))) (list (cursor 0 2 (hash 'face 'cursor) #t)) '()))
(show "(screen-compose 1 6 [left@0 right@3] 'right) 文本"
      (screen-row (screen-compose 1 6 (list (pane 'left 0 0 left) (pane 'right 3 0 right)) 'right) 0))
(show "(screen-compose ... 'right) 光标" (screen-cursors (screen-compose 1 6 (list (pane 'left 0 0 left) (pane 'right 3 0 right)) 'right)))
(show "(screen-compose ... 'left) 光标" (screen-cursors (screen-compose 1 6 (list (pane 'left 0 0 left) (pane 'right 3 0 right)) 'left)))

;;; ===========================================================================
(header "6. project —— window → screen（含行号栏、选区、多光标）")
;;; ===========================================================================

;; window->screen : window [provider] → screen
;;   设计：把「① 视觉行 ② 渲染 ③ overlay」合成一帧。provider 是 **buffer 层**：(buffer line) → runs。
;;   用法：每帧投一个 window；多窗格各自投完再 screen-compose。
(show "(window->screen w0) 行文本" (map (lambda (i) (screen-row->string (window->screen w0) i)) '(0 1)))
(show "(window->screen w0) 光标" (screen-cursors (window->screen w0)))
(show "(window->screen 带派生 face) 行0"
      (screen-row (window->screen w0 hl-provider) 0))
(show "(window->screen 选区) regions"
      (screen-selections (window->screen ws)))
;; 行号栏（视图装饰）：前缀 run face = 'line-number，正文右移
(show "(window->screen 开行号) 行0"
      (screen-row (window->screen (window-set-line-numbers w0 #t)) 0))

;;; ===========================================================================
(header "7. mirror —— 视口同步（window → window，两个 document 之间）")
;;; ===========================================================================

;; 设计：与 rebase 的区别——rebase 是「edit → window」（按 edit-desc 在**同一**坐标空间重定位）；
;;   mirror 是「window → window」（两个文档之间同步视口），**不吃 edit-desc**。
;;   规则：行**固定行号**（目标更短则夹最近）；列按该行字符长**比例**；目标 document/选区原样保留。

;; mirror-point : document point document → point（逻辑映射，与 mode 无关）
(define dA (document-open "l0\nl1\nl2\nl3"))
(define dB (document-open "m0\nm1"))
(show "(mirror-point dA (point 3 0) dB)  # 行夹到最近" (mirror-point dA (P 3 0) dB))
(define sA (document-open "abcd"))
(define sB (document-open "ab"))
(show "(mirror-point sA (point 0 4) sB)  # 列按比例 4/4*2" (mirror-point sA (P 0 4) sB))

;; mirror-window : window window → window（把源可视区投到目标，按目标 mode 定位视口）
(define w-src (window-set-top-line (window-open (document-open "l0\nl1\nl2\nl3") 2 10) 2))
(define w-dst (window-open (document-open "m0\nm1\nm2\nm3") 2 10))
(show "(mirror-window src dst) → top-line" (window-top-line (mirror-window w-src w-dst)))

(printf "\napi/3-render.rkt 跑完（没有报错）。\n")
