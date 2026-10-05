#lang racket

(require "../../core/editor.rkt"
         "../base/layout/main.rkt"
         "../ui/slot.rkt"
         "../ui/mode.rkt"
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

;;; ---------- 补全弹层（装饰图层） ----------
;;;
;;; 不占布局、不动焦点：直接贴在光标下一行、光标列处的一个高 deep pane（合成时压在最上）。
;;; 选中项用 cursor overlay（反色）+ state face；其余用 state face。

(define complete-face 'state)
(define complete-max-rows 10)

(define (app-complete-panes a)
  (define m (app-mode a))
  (cond
    [(not (complete? m)) '()]
    [else
     (define ed (app-ed a))
     (define vid (complete-prev-focus m))
     (define cands (complete-candidates m))
     (define idx (complete-index m))
     (define n (length cands))
     (define h (min complete-max-rows n))
     ;; 让选中项大致居中，并按窗口夹在 [0, n-h]
     (define start (max 0 (min (- idx (quotient h 2)) (- n h))))
     (define shown (take (drop cands start) h))
     (define w (+ 2 (for/fold ([mx 0]) ([s (in-list shown)]) (max mx (string-length s)))))
     (define-values (row col)
       (editor-view-point->screen-position ed vid (editor-view-point ed vid)))
     (define rows
       (for/vector ([i (in-range h)])
         (define s (list-ref shown i))
         (define selected? (= (+ start i) idx))
         (define pad (max 0 (- w (add1 (string-length s)))))
         (list (run 0 (string-append " " s (make-string pad #\space))
                    (if selected? (cons 'cursor complete-face) complete-face)))))
     (list (pane 'complete (add1 row) col (screen w h rows '() '()) 10))]))

;; 本帧全部装饰图层：分隔线 + 补全弹层 + 文档浮窗。纯渲染与增量后端都走这一个入口。
(define (app-overlay-panes a)
  (append (app-bar-panes a) (app-complete-panes a) (app-docs-panes a)))

;;; ---------- 文档浮窗（装饰图层） ----------
;;;
;;; 居中一个带边框的框，内容已折好行；Enter/Esc 关、上下滚（键表在 config/keys）。

(define docs-border-face 'bar)
(define docs-text-face 'state)

(define (app-docs-panes a)
  (define m (app-mode a))
  (cond
    [(not (docs? m)) '()]
    [else
     (define lines (docs-lines m))
     (define n (vector-length lines))
     (define cw (docs-width m))
     (define content-rows (max 1 (min (docs-rows m) n)))
     (define off (max 0 (min (docs-offset m) (max 0 (- n content-rows)))))
     (define w (+ cw 2))
     (define h (+ content-rows 2))
     ;; 锚点：光标下一行、光标列（加窗格偏移 → 屏幕绝对坐标）；放不下就贴边。
     (define ed (app-ed a))
     (define vid (docs-vid m))
     (define rect
       (for/first ([r (in-list (layout-result-panes (app-layout-result a)))]
                   #:when (eqv? (rectangle-view-id r) vid)) r))
     (define-values (crow ccol) (editor-view-point->screen-position ed vid (docs-point m)))
     (define anchor-row (if rect (+ (rectangle-y rect) crow) crow))
     (define anchor-col (if rect (+ (rectangle-x rect) ccol) ccol))
     (define top-row (max 0 (min (add1 anchor-row) (max 0 (- (app-height a) h)))))
     (define left-col (max 0 (min anchor-col (max 0 (- (app-width a) w)))))
     (define (hborder) (run 0 (string-append "+" (make-string cw #\-) "+") docs-border-face))
     (define (content-row i)
       (define s (vector-ref lines (+ off i)))
       (define pad (make-string (max 0 (- cw (string-length s))) #\space))
       (list (run 0 "|" docs-border-face)
             (run 1 (string-append s pad) docs-text-face)
             (run (add1 cw) "|" docs-border-face)))
     (define rows
       (for/vector ([i (in-range h)])
         (cond
           [(zero? i) (list (hborder))]
           [(= i (sub1 h)) (list (hborder))]
           [else (content-row (sub1 i))])))
     (list (pane 'docs top-row left-col (screen w h rows '() '()) 11))]))

;; 一次性全量渲染（测试 / 非增量后端用）：与增量后端走**同一个** app-prepare! 入口。
(define (app-render a)
  (define panes (app-prepare! a))
  (editor-render-layout*! (app-ed a)
                          panes
                          (app-focus a) (app-width a) (app-height a)
                          (app-overlay-panes a)))
