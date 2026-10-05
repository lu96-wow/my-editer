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

(provide app-state-refresh! app-prepare! app-bar-panes app-render)

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

;; 一次性全量渲染（测试 / 非增量后端用）：与增量后端走**同一个** app-prepare! 入口。
(define (app-render a)
  (define panes (app-prepare! a))
  (editor-render-layout*! (app-ed a)
                          panes
                          (app-focus a) (app-width a) (app-height a)
                          (app-bar-panes a)))
