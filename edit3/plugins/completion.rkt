#lang racket

;;; edit3/plugins/completion.rkt —— 补全（不抢焦点的浮窗菜单，参考 edit/）
;;;
;;; 关键点（对齐 edit/ 的补全）：
;;;   · 菜单是**不抢焦点**的浮窗：编辑器保持焦点与光标，所以能**边打边筛**；
;;;   · 菜单随光标落位（below/above，见 popup 规则），由 before-render 钩子每帧重算；
;;;   · 候选窗口按 popup-window 滚动，选中项始终可见；行铺满，选中行用
;;;     'complete-selected、其余用 'complete（颜色）。
;;;   · Up/Down/Tab/Enter/Esc 用「有菜单就操作菜单、否则回落原行为」的 op 接住；
;;;     打字走基础 insert，after-insert/after-edit 钩子重筛。
;;; 目前同步候选（本地词表 + Racket 关键字）；换异步 worker 只需替换 all-words。

(require racket/string racket/list
         "../core/extension.rkt"
         "../config/syntax.rkt")

(provide completion-spec)

;;; ---------- popup 内容窗口（纯几何，取自 edit/geometry/popup.rkt） ----------

;; n 项里以 idx 为中心、最多 cap 行的窗口。→ (values start rows)
(define (popup-window n idx cap)
  (define rows (max 1 (min n (max 1 cap))))
  (values (max 0 (min (- idx (quotient rows 2)) (- n rows))) rows))

;;; ---------- 候选 ----------

(define (line-at ed did line)
  (define lines (string-split (document-string ed did) "\n"))
  (if (< line (length lines)) (list-ref lines line) ""))

(define (prefix-at ed vid)
  (define did (view-did ed vid))
  (define s (line-at ed did (view-line ed vid)))
  (define c (min (view-col ed vid) (string-length s)))
  (define start (let loop ([i c])
                  (if (and (> i 0) (symbol-char? (string-ref s (sub1 i)))) (loop (sub1 i)) i)))
  (substring s start c))

(define (all-words st)
  (define ed (state-ed st))
  (define from-docs
    (for*/list ([did (in-list (document-id-list ed))]
                #:unless (panel-name? st (document-name ed did))
                [line (in-list (string-split (document-string ed did) "\n"))]
                [m (in-list (line-tokens line))])
      (substring line (car m) (cdr m))))
  (sort (remove-duplicates (append from-docs (hash-keys keyword-categories))) string<?))

(define (filter-pool pool prefix)
  (define plen (string-length prefix))
  (for/list ([w (in-list pool)]
             #:when (and (>= (string-length w) plen)
                         (string=? prefix (substring w 0 plen))
                         (not (string=? w prefix))))
    w))

;;; ---------- 菜单浮窗 ----------

(define (completion-vid st) (panel-vid st "*completion*"))

(define (completion-float st)
  (define cv (completion-vid st))
  (and cv (for/first ([f (in-list (state-floats st))] #:when (eqv? cv (float-vid f))) (float-wid f))))

(define (menu-open? st) (and (feature-ref st 'completion #f) (completion-float st) #t))

(define (completion-close st)
  (define w (completion-float st))
  (feature-set (if w (remove-wid* st w) st) 'completion #f))

;; 菜单每帧落位 + 尺寸：随光标（below/above），窗口滚动。
(define (reposition st size)
  (define c (feature-ref st 'completion #f))
  (define w (completion-float st))
  (cond
    [(or (not c) (not w) (not size)) st]
    [else
     (define cands (hash-ref c 'candidates))
     (define idx (hash-ref c 'index))
     (define maxlen (for/fold ([m 0]) ([x (in-list cands)]) (max m (string-length x))))
     (define cap (min 8 (length cands)))
     (define-values (_start rows) (popup-window (length cands) idx cap))
     (define W (car size)) (define H (cdr size))
     (define width (min (max 12 (+ maxlen 3)) (max 3 (- W 2))))
     (define height (+ rows 2))
     (define tv (hash-ref c 'target-vid))
     (define ed (state-ed st))
     (define pos (and (memv tv (view-id-list ed))
                      (point->screen ed tv (view-line ed tv) (view-col ed tv))))
     (define col (if pos (cdr pos) 0))
     (define row (if pos (car pos) 0))
     (define dy (if (<= (+ row 1 height) H) (add1 row) (max 0 (- row height))))
     (define a (anchor (hash-ref c 'target-w) 'left 'top col dy))
     (define f (float w (completion-vid st) a (cons width height) 'window-border))
     (struct-copy state st [floats (set-float (state-floats st) w f)])]))

;;; ---------- 菜单面板 ----------

(define (completion-content st _v)
  (define c (feature-ref st 'completion #f))
  (cond
    [(not c) (values "" '())]
    [else
     (define cands (hash-ref c 'candidates))
     (define idx (hash-ref c 'index))
     (define cap (min 8 (length cands)))
     (define-values (start rows) (popup-window (length cands) idx cap))
     (define shown (take (drop cands start) rows))
     (define content-w (for/fold ([m 1]) ([x (in-list cands)]) (max m (+ 1 (string-length x)))))
     (values
      (string-join (for/list ([x (in-list shown)])
                     (define base (string-append " " x))
                     (string-append base (make-string (max 0 (- content-w (string-length base))) #\space)))
                   "\n")
      (for/list ([i (in-range rows)])
        (cons i (if (= (+ start i) idx) 'complete-selected 'complete))))]))

;;; ---------- 行为 ----------

(define (complete-move st d)
  (define c (feature-ref st 'completion #f))
  (cond
    [(not c) st]
    [else
     (define n (length (hash-ref c 'candidates)))
     (feature-set st 'completion (hash-set c 'index (modulo (+ (hash-ref c 'index) d) n)))]))

;; 打字 / 删除后按新前缀重筛；前缀空或无候选则关。
(define (refine st)
  (define c (feature-ref st 'completion #f))
  (cond
    [(not c) st]
    [else
     (define v (hash-ref c 'target-vid))
     (define ed (state-ed st))
     (cond
       [(not (memv v (view-id-list ed))) (completion-close st)]
       [else
        (define prefix (prefix-at ed v))
        (cond
          [(zero? (string-length prefix)) (completion-close st)]
          [else
           (define cands (filter-pool (hash-ref c 'pool) prefix))
           (cond
             [(null? cands) (completion-close st)]
             [else
              (define idx (min (hash-ref c 'index) (sub1 (length cands))))
              (feature-set st 'completion
                           (hash-set (hash-set (hash-set c 'candidates cands) 'index idx) 'prefix prefix))])])])]))

;;; ---------- op ----------

(define (completion-start ctx st _ev _args)
  (define vid (focused-vid st))
  (cond
    [(or (not vid) (panel-name-of-vid st vid) (menu-open? st)) (values st '())]
    [else
     (define ed (state-ed st))
     (define prefix (prefix-at ed vid))
     (cond
       [(zero? (string-length prefix)) (values st '())]
       [else
        (define pool (all-words st))
        (define cands (filter-pool pool prefix))
        (cond
          [(null? cands) (values st '())]
          [else
           (define c0 (hash 'candidates cands 'index 0 'prefix prefix 'pool pool
                            'target-vid vid 'target-w (state-focus st)))
           (define st1 (feature-set st 'completion c0))
           (define st2 (open-float-overlay* st1 (completion-vid st1)
                                            (anchor (state-focus st1) 'left 'top 0 1)
                                            (cons 12 3) 'window-border))
           (values (reposition st2 (ctx-size ctx)) '())])])]))

(define (complete-next _ctx st _ev _args) (values (if (menu-open? st) (complete-move st 1) st) '()))
(define (complete-prev _ctx st _ev _args) (values (if (menu-open? st) (complete-move st -1) st) '()))

(define (complete-accept _ctx st _ev _args)
  (define c (feature-ref st 'completion #f))
  (cond
    [(not c) (values st '())]
    [else
     (define cand (list-ref (hash-ref c 'candidates) (hash-ref c 'index)))
     (define prefix (hash-ref c 'prefix))
     (define tvid (hash-ref c 'target-vid))
     (define ins (substring cand (min (string-length prefix) (string-length cand))))
     (insert! (state-ed st) tvid ins)
     (values (completion-close st) '())]))

;; Up/Down：有菜单移候选，否则回落普通导航（并补发 after-nav）。
(define (complete-or-move _ctx st _ev args)
  (define dir (car args))
  (cond
    [(menu-open? st) (values (complete-move st (if (eq? dir 'up) -1 1)) '())]
    [else
     (define v (focused-vid st))
     (cond
       [(not v) (values st '())]
       [else (nav! (state-ed st) v dir #f)
             (values (emit st 'after-nav (list v)) '())])]))

(define (complete-or-enter ctx st ev args)
  (cond
    [(menu-open? st) (complete-accept ctx st ev args)]
    [else
     (define v (focused-vid st))
     (cond
       [(not v) (values st '())]
       [else (insert! (state-ed st) v "\n")
             (values (emit st 'after-insert (list v "\n")) '())])]))

(define (complete-or-cancel _ctx st _ev _args)
  (values (if (menu-open? st) (completion-close st) st) '()))

;;; ---------- 插件 ----------

(define completion-spec
  (make-plugin
   #:name 'completion
   #:ops (list (cons 'complete-start completion-start)
               (cons 'complete-next complete-next)
               (cons 'complete-prev complete-prev)
               (cons 'complete-accept complete-accept)
               (cons 'complete-or-move complete-or-move)
               (cons 'complete-or-enter complete-or-enter)
               (cons 'complete-or-cancel complete-or-cancel))
   #:panels (list (panel-spec "*completion*" #f completion-content))
   #:key-tables (list '(((key / alt) editor (complete-start))
                        ((key down) editor (complete-or-move down))
                        ((key up)   editor (complete-or-move up))
                        ((key tab)  editor (complete-next))
                        ((key enter) editor (complete-or-enter))
                        ((key escape) editor (complete-or-cancel))))
   #:hooks (list (reaction* 'after-insert (lambda (s _args) (refine s)))
                 (reaction* 'after-edit   (lambda (s _args) (refine s)))
                 (reaction* 'before-render
                            (lambda (s args)
                              (if (and (pair? args) (car args)) (reposition s (car args)) s))))))
