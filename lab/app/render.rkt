#lang racket

(require "../../core/editor.rkt"
         "../base/layout/main.rkt"
         "../base/wrap.rkt"
         "../ui/slot.rkt"
         "../ui/mode.rkt"
         "../lang/docs.rkt"
         "../plugin/seam.rkt"
         "../core/state.rkt"
         "../core/panes.rkt")

;;; lab-rebuild/app/render.rkt —— 每帧准备 + 分隔线 + 底部 state 行
;;;
;;; app-prepare! 是渲染前**唯一入口**：先刷新底部 state 槽位，再返回本帧窗格。
;;; 纯渲染（app-render）和增量渲染（backend/tui）都必须走它，别各写一份。
;;; 分屏的分隔线（bars）作为**装饰图层**参与合成（app-bar-panes），也走同一条 patch 路径。

(provide app-state-refresh! app-prepare! app-bar-panes app-complete-panes app-overlay-panes app-render)

(define (pad-right s n)
  (define len (string-length s))
  (if (>= len n) (substring s 0 n) (string-append s (make-string (- n len) #\space))))

;; 焦点所在的 pane。
(define (focus-label a vid)
  (define p (app-panes a))
  (cond [(eqv? vid (panes-tree p)) "tree"]
        [(eqv? vid (panes-bufs p)) "buffers"]
        [else "edit"]))

;; 状态栏：焦点 + 行:列 + 该 view 对应 document 的文件名；前缀激活时附提示。
(define (state-line a)
  (define vid (app-focus a))
  (define ed (app-ed a))
  (define base
    (cond
      [(not vid) ""]
      [else
       (define did (editor-view-document-id ed vid))
       (format "~a  ~a:~a  ~a"
               (focus-label a vid)
               (add1 (editor-view-point-line ed vid))
               (add1 (editor-view-point-column ed vid))
               (editor-document-name ed did))]))
  (define m (app-mode a))
  (if (prefix? m) (format "~a  [~a-]" base (prefix-label m)) base))

;;; ---------- state 行：增量更新 ----------
;;;
;;; 原来每变一次就 state->document 重建整篇 + editor-view-assign!。
;;; 现在只算 old→new 的最小 diff（公共前缀 / 后缀），用一次 ignore-readonly 编辑
;;; 替换中间段；只给**新插入**的字符补 face / readonly（其余格随编辑平移），
;;; 再清掉这一步的历史（状态栏不该进撤销栈）。

(define (common-prefix-len a b)
  (define n (min (string-length a) (string-length b)))
  (or (for/first ([i (in-range n)]
                  #:unless (char=? (string-ref a i) (string-ref b i)))
        i)
      n))

(define (common-suffix-len a b limit)
  (define n (min limit (min (string-length a) (string-length b))))
  (or (for/first ([i (in-range n)]
                  #:unless (char=? (string-ref a (- (string-length a) 1 i))
                                   (string-ref b (- (string-length b) 1 i))))
        i)
      n))

(define (state-line-apply! ed vid old new)
  (define olen (string-length old))
  (define nlen (string-length new))
  (define p (common-prefix-len old new))
  (define q (common-suffix-len old new (min (- olen p) (- nlen p))))
  (define new-mid (substring new p (- nlen q)))
  ;; 选中旧中间段（空 = 纯插入），插 new-mid 替换它（空 = 纯删除）。
  ;; #:ensure? #f：不要让“把光标带进视口”的滚动把 state 行横向滚走（否则渲染会缺首字符）。
  (editor-view-set-selections!
   ed vid
   (selections-one (selection (point 0 p) (point 0 (- olen q))))
   #:ensure? #f)
  (editor-view-insert-ignore-readonly! ed vid new-mid)
  ;; 新插入的字符属性是默认 #f → 补上状态栏样式
  (unless (zero? (string-length new-mid))
    (define doc (editor-document-handle ed (editor-view-document-id ed vid)))
    (define end (+ p (string-length new-mid)))
    (document-highlight-fill-batch doc (list (list 0 p 0 end state-face)))
    (document-readonly-fill-batch doc (list (list 0 p 0 end #t))))
  (editor-view-clear-history! ed vid)
  ;; 插字后光标落在行尾，install 的 ensure 会把 left-column 推到 1（显示从第 2 列开始，
  ;; “tree/edit” 就成 “ree/dit”）。state 行是展示槽，固定钉在左上角。
  (editor-view-set-left-column! ed vid 0)
  (editor-view-set-top-line! ed vid 0))

;; prompt 时底部显示 input（不刷 state）；空闲 / 前缀都刷 state。
(define (app-state-refresh! a)
  (unless (prompt? (app-mode a))
    (define ed (app-ed a))
    (define vid (panes-state (app-panes a)))
    (define s (pad-right (state-line a) (app-main-w a)))
    (define cur (editor-view-string ed vid))
    (unless (equal? s cur)
      (state-line-apply! ed vid cur s))))

(define (app-prepare! a)
  (app-state-refresh! a)
  (app-plugin-tick! a)                                  ; 插件：派活 + 收结果
  (layout-result-panes (app-layout-result a)))

;;; ---------- 分屏分隔线（装饰图层） ----------

(define bar-face 'bar)

;; 一条 bar → 一块 1 格宽 / 高的子屏（lr 竖线 │，tb 横线 ─）。
(define (bar->pane b)
  (define vertical? (eq? (bar-dir b) 'lr))
  (define w (bar-width b))
  (define h (bar-height b))
  (define ch (if vertical? #\u2502 #\u2500))
  (define rows
    (if vertical?
        (for/vector ([_ (in-range h)]) (list (run 0 (string ch) bar-face)))
        (vector (list (run 0 (make-string w ch) bar-face)))))
  (pane 'bar (bar-y b) (bar-x b) (screen w h rows '() '()) 1))

(define (app-bar-panes a)
  (for/list ([b (in-list (layout-result-bars (app-layout-result a)))]
             #:when (and (positive? (bar-width b)) (positive? (bar-height b))))
    (bar->pane b)))

;;; ---------- 浮层公共 ----------
;;
;; 光标所在编辑 view 的屏幕绝对坐标（视口内坐标 + 窗格 x/y）。
;; ⚠ 光标被滚出视口时，editor-view-point->screen-position 返回 (values #f #f)；
;; 此处原样透传 → 调用方跳过浮层（否则对 #f 做算术会崩）。
(define (anchor-screen-pos a vid p)
  (define ed (app-ed a))
  (define rect
    (for/first ([r (in-list (layout-result-panes (app-layout-result a)))]
                #:when (eqv? (rectangle-view-id r) vid)) r))
  (define-values (row col) (editor-view-point->screen-position ed vid p))
  (if row
      (values (if rect (+ (rectangle-y rect) row) row)
              (if rect (+ (rectangle-x rect) col) col))
      (values #f #f)))

;; 实线框（box-drawing）——补全面板 / 文档浮窗共用，比 +-| 好看。
(define box-bface 'bar)         ; 边框 face
(define box-tface 'state)       ; 文本 face
(define box-h #\u2500) (define box-v #\u2502)
(define box-tl #\u250c) (define box-tr #\u2510)
(define box-bl #\u2514) (define box-br #\u2518)
(define box-lt #\u251c) (define box-rt #\u2524)

;; 一条横框线（left / right 选角或分隔接点），内宽 cw。
(define (box-hline cw left right)
  (run 0 (string-append (string left) (make-string cw box-h) (string right)) box-bface))

;; 一条内容行：│ text ␣… │；face 可带 overlay（选中行）。
(define (box-line cw text face)
  (list (run 0 (string box-v) box-bface)
        (run 1 (string-append text (make-string (max 0 (- cw (string-length text))) #\space)) face)
        (run (add1 cw) (string box-v) box-bface)))

;; 一个实线框 pane：content 是内容行（每行 (text . face)）。
(define (frame-pane id row col cw content deep)
  (define rws
    (list->vector
     (append (list (list (box-hline cw box-tl box-tr)))
             (for/list ([c (in-list content)]) (box-line cw (car c) (cdr c)))
             (list (list (box-hline cw box-bl box-br))))))
  (pane id row col (screen (+ cw 2) (+ (length content) 2) rws '() '()) deep))

;;; ---------- 补全弹层（装饰图层） ----------
;;;
;;; 不占布局、不动焦点：贴光标行下侧，下侧放不下就翻到上侧（绝不遮输入行）。
;;; 菜单始终贴光标行（下侧时菜单在上，上侧时菜单在下），选中项 bluebox 文档放远端，
;;; 同一个实线框；选中行用 cursor overlay（反色）。

(define complete-face 'state)
(define complete-max-rows 10)
(define complete-doc-max-rows 18)

;; 光标在视口内时：按锚点 (arow, acol) 拼补全弹层。
(define (complete-panes-at a m vid d arow acol)
  (define cands (complete-candidates m))
  (define idx (complete-index m))
  (define n (length cands))
  ;; 可见窗口高度有限：光标行上 / 下各有多少行可用（不含光标行本身）。
  (define avail-below (- (app-height a) (add1 arow)))
  (define avail-above arow)
  ;; 内容行预算取上 / 下更大的那侧（先定高度，再决定放哪侧，保证至少一侧放得下）
  (define budget (max 1 (- (max avail-above avail-below) 2)))
  (define mrows (min complete-max-rows n budget))
  ;; 让选中项大致居中，并按窗口夹在 [0, n-mrows]
  (define start (max 0 (min (- idx (quotient mrows 2)) (- n mrows))))
  (define shown (take (drop cands start) mrows))
  (define menu-cw (+ 2 (for/fold ([mx 0]) ([s (in-list shown)]) (max mx (string-length s)))))
  (define max-cw (max 10 (- (app-width a) 4)))
  (define inner (min max-cw (max menu-cw (if d 48 0))))
  ;; 文档行数：预算内、上限 18
  (define doc-budget (max 0 (- budget mrows (if d 1 0))))
  (define doc-lines (and d (list->vector (wrap-lines (doc->text d) inner))))
  (define doc-rows
    (if doc-lines (max 0 (min complete-doc-max-rows (vector-length doc-lines) doc-budget)) 0))
  (define show-doc? (and d (positive? doc-rows)))
  ;; 先拼内容行（text . face）
  (define menu-rows
    (for/list ([i (in-range mrows)])
      (define s (list-ref shown i))
      (define selected? (= (+ start i) idx))
      (cons (string-append " " s) (if selected? (cons 'cursor complete-face) complete-face))))
  (define doc-row-list
    (if show-doc?
        (for/list ([i (in-range doc-rows)]) (cons (vector-ref doc-lines i) complete-face))
        '()))
  (define menu-body (for/list ([c (in-list menu-rows)]) (box-line inner (car c) (cdr c))))
  (define doc-body (for/list ([c (in-list doc-row-list)]) (box-line inner (car c) (cdr c))))
  (define sep (list (list (box-hline inner box-lt box-rt))))   ; 一条分隔**行**（body 是行的列表）
  (define h (+ mrows (if show-doc? (+ 1 doc-rows) 0) 2))
  ;; 位置：优先光标行**下侧**；下侧放不下就翻到**上侧**（箱底贴着光标行），
  ;; 两侧都不够时取更宽的那侧，绝不遮住光标所在输入行。
  ;; 菜单始终贴光标行：下侧时菜单在上，上侧时菜单在下（文档放远端）。
  (define above? (> h avail-below))
  (define body
    (if above?
        (append doc-body (if show-doc? sep '()) menu-body)
        (append menu-body (if show-doc? sep '()) doc-body)))
  (define top (if above? (max 0 (- arow h)) (add1 arow)))
  (define left (max 0 (min acol (max 0 (- (app-width a) (+ inner 2))))))
  (define rws (list->vector (append (list (list (box-hline inner box-tl box-tr)))
                                    body
                                    (list (list (box-hline inner box-bl box-br))))))
  (list (pane 'complete top left (screen (+ inner 2) h rws '() '()) 10)))

(define (app-complete-panes a)
  (define m (app-mode a))
  (cond
    [(not (complete? m)) '()]
    [else
     (define ed (app-ed a))
     (define vid (complete-prev-focus m))
     ;; 光标被滚出视口 → 没地方贴，先不画（滚回来再出现）。
     (define-values (arow acol) (anchor-screen-pos a vid (editor-view-point ed vid)))
     (if arow
         (complete-panes-at a m vid (complete-doc m) arow acol)
         '())]))

;; 本帧全部装饰图层：分隔线 + 补全弹层 + 文档浮窗。纯渲染与增量后端都走这一个入口。
(define (app-overlay-panes a)
  (append (app-bar-panes a) (app-complete-panes a) (app-docs-panes a)))

;;; ---------- 文档浮窗（装饰图层） ----------
;;;
;;; 贴在光标上一行 / 下一行（哪边不遮输入行就放哪边）；内容已折好行；
;;; Enter/Esc 关、上下滚（键表在 config/keys）。

(define (app-docs-panes a)
  (define m (app-mode a))
  (cond
    [(not (docs? m)) '()]
    [else
     (define lines (docs-lines m))
     (define n (vector-length lines))
     (define cw (docs-width m))
     (define rows (max 1 (min (docs-rows m) n)))
     (define h (+ rows 2))
     (define-values (arow acol) (anchor-screen-pos a (docs-vid m) (docs-point m)))
     (cond
       [(not arow) '()]                                ; 光标滚出视口 → 先不画
       [else
        ;; 优先光标行下侧；放不下就翻到上侧（底边贴光标行），不遮输入行。
        (define avail-below (- (app-height a) (add1 arow)))
        (define top (if (<= h avail-below) (add1 arow) (max 0 (- arow h))))
        (define left (max 0 (min acol (max 0 (- (app-width a) (+ cw 2))))))
        (define off (max 0 (min (docs-offset m) (max 0 (- n rows)))))
        (define content (for/list ([i (in-range rows)]) (cons (vector-ref lines (+ off i)) box-tface)))
        (list (frame-pane 'docs top left cw content 11))])]))

;; 一次性全量渲染（测试 / 非增量后端用）：与增量后端走**同一个** app-prepare! 入口。
(define (app-render a)
  (define panes (app-prepare! a))
  (editor-render-layout*! (app-ed a)
                          panes
                          (app-focus a) (app-width a) (app-height a)
                          (app-overlay-panes a)))
