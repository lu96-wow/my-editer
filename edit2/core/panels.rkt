#lang racket

;;; edit2/panels.rkt —— 面板（树 / 缓冲区 / 状态 / 日志）
;;;
;;; **一切皆 document**：每个面板就是一个 vid 显示一个生成的 doc。
;;; 面板的「选择 / 光标」就是这个 doc 视图的光标（view point），不是另设的游标；
;;; 导航就是文档导航，回车用光标行取行，点击用同一套屏幕→document 定位。
;;; 面板内容由 State 纯投影成文本 + face，写回这个 doc。

(provide
 (struct-out tree)
 (struct-out region)
 (struct-out panel-spec)
 (struct-out panel-registry)
 region-members region-side region-size region-anchor
 panel-doc-name parse-region
 panel-register panel-lookup panel-names base-panel-registry state-panels
 panel-name? panel-vid panel-name
 refresh-panels! buffer-items buffer-rows tree-relative-path
 tree-content
 tree-init tree-ensure tree-rows tree-toggle-dir tree-expand-dir tree-parent-dir tree-refresh
 tree-toggle-hidden
 panel-line panel-line-at)

(require racket/path
         "state.rkt" "adapter.rkt" "fs.rkt" "layout.rkt")

;;; ---------- 区域（共享同一块面板的多个成员，互斥显示） ----------

;; anchor = 'root（贴在整棵布局的根上，跨满整屏）| 'main（贴在主区里，让开外层状态栏）
(struct region (id side size members anchor) #:transparent)

;; 面板 id（symbol）↔ 文档名（string）。
(define (panel-doc-name id) (if (symbol? id) (format "*~a*" id) id))

;; 配置数据 (id side size (member ...) [anchor]) → region 结构；anchor 缺省 'main。
(define (parse-region d)
  (define id (first d))
  (define side (second d))
  (define size (third d))
  (define members (list-ref d 3))
  (define anchor (if (>= (length d) 5) (list-ref d 4) 'main))
  (region id side size (map panel-doc-name members) anchor))

;;; ---------- 面板注册表（可注册、可组合） ----------
;;;
;;; 一个面板 = (panel-spec name prep render)：
;;;   prep   : (st -> st) | #f                         每帧刷新前跑（可更新 feature，如树缓存）
;;;   render : (st v -> (values text faces)) | #f      内容投影；#f = 不重建（用户文本/静态）
;;; 注册表是**纯值**：panel-register 返回新表；插件用它加自己的面板。
;;; 「注册」（本模块）与「启用哪些」（config/enabled-panels）是分开的两件事。
(struct panel-spec (name prep render) #:transparent)
(struct panel-registry (specs) #:transparent)

(define (panel-register reg spec)
  (panel-registry
   (cons spec (filter (lambda (s) (not (equal? (panel-spec-name s) (panel-spec-name spec))))
                      (panel-registry-specs reg)))))

(define (panel-lookup reg name)
  (for/first ([s (in-list (panel-registry-specs reg))] #:when (equal? name (panel-spec-name s))) s))

(define (panel-names reg) (map panel-spec-name (panel-registry-specs reg)))

;; 面板名集合存在 State feature 'panels（boot 时写入注册表）。
(define (state-panels st) (feature-ref st 'panels base-panel-registry))
(define (state-panel-names st) (panel-names (state-panels st)))

(define (panel-name? st name)
  (and (string? name) (and (member name (state-panel-names st)) #t)))

(define (panel-vid st name)
  (define ed (state-ed st))
  (for/first ([vid (in-list (view-id-list ed))]
              #:when (equal? name (view-document-name ed vid)))
    vid))

(define (panel-name st vid)
  (define ed (state-ed st))
  (define n (and vid (view-document-name ed vid)))
  (and (panel-name? st n) n))

;; 面板文档视图的光标行 = 该面板的「选择行」（一切皆 document）。
(define (panel-line st name)
  (define v (panel-vid st name))
  (and v (view-line (state-ed st) v)))

;; 光标行对应的行文本（超界 → #f）。
(define (panel-line-at st name)
  (define v (panel-vid st name))
  (and v
       (let* ([text (view-string (state-ed st) v)]
              [lines (string-split text "\n")]
              [i (view-line (state-ed st) v)])
         (and (< i (length lines)) (list-ref lines i)))))

;;; ---------- 树状态（纯）：只放真正不是文档的东西 ----------

;; root / 展开集 / 目录快照缓存 / 是否显示隐藏项。**没有游标**——选择就是面板文档的光标。
(struct tree (root expanded children show-hidden?) #:transparent)

(define (tree-init root) (tree (simplify-path (path->complete-path root)) (hash) (hash) #f))

;; 清空目录快照缓存 → 下次 tree-ensure 重读磁盘（只影响树，不动已打开文档）。
(define (tree-refresh ts) (struct-copy tree ts [children (hash)]))

;; C-h：显示 / 隐藏以 . 开头的条目。
(define (tree-toggle-hidden ts)
  (struct-copy tree ts [show-hidden? (not (tree-show-hidden? ts))]))

(define (tree-ensure ts)
  (define dirs (cons (tree-root ts) (hash-keys (tree-expanded ts))))
  (define ch
    (for/fold ([ch (tree-children ts)]) ([d (in-list dirs)] #:unless (hash-has-key? ch d))
      (hash-set ch d (with-handlers ([exn:fail? (lambda (_) '())]) (fs-read-dir d)))))
  (struct-copy tree ts [children ch]))

;; 以 . 开头的条目（隐藏路径）。
(define (tree-hidden-path? p)
  (define n (path->string (file-name-from-path p)))
  (and (positive? (string-length n)) (char=? #\. (string-ref n 0))))

;; 可见行：(path name dir? depth)。顶部第一行是工作区根目录。
(define (tree-rows ts)
  (define show? (tree-show-hidden? ts))
  (define (walk dir depth)
    (append*
     (for/list ([e (in-list (hash-ref (tree-children ts) dir '()))]
                #:unless (and (not show?) (tree-hidden-path? (car e))))
       (define p (car e)) (define d? (cdr e))
       (cons (list p (path->string (file-name-from-path p)) d? depth)
             (if (and d? (hash-has-key? (tree-expanded ts) p)) (walk p (add1 depth)) '())))))
  (define root (tree-root ts))
  (cons (list root (path->string root) #t 0)
        (walk root 1)))

(define (tree-toggle-dir ts dir)
  (struct-copy tree ts
               [expanded (if (hash-has-key? (tree-expanded ts) dir)
                             (hash-remove (tree-expanded ts) dir)
                             (hash-set (tree-expanded ts) dir #t))]))
(define (tree-expand-dir ts dir)
  (struct-copy tree ts [expanded (hash-set (tree-expanded ts) dir #t)]))
(define (tree-parent-dir p)
  (define d (path-only p))
  (and d (not (equal? (simplify-path d) (simplify-path p))) (simplify-path d)))

;;; ---------- 内容（text + face） ----------

(define (status-content st v)
  (define w (state-focus st))
  (define v (and w (layout-wid-vid (state-layout st) w)))   ; focus 是 wid；取显示的 vid
  (cond
    [(placing? (feature-ref st 'placing #f))
     (define target (if v (doc-label st (view-did (state-ed st) v)) "(空窗口)"))
     (values (format " 选择目标窗口: ~a   Tab / M-n 切换   Enter 替换   Esc 取消" target)
             (list (cons 0 'status-bar)))]
    [else
     (define ed (state-ed st))
     (define txt
       (cond
         [(not v) ""]                     ; 焦点是空窗口 → 不显示提示
         [else
          (define did (view-did ed v))
          (define m (hash-ref (state-docs st) did #f))
          (define pth (and m (doc-meta-path m)))
          (define name (if pth (tree-relative-path st pth) (view-document-name ed v)))
          (define dirty (and m (doc-meta-saved m)
                             (not (eq? (doc-meta-saved m) (document-handle ed did)))))
          (format " ~a~a   ~a:~a" name (if dirty " *" "")
                  (add1 (view-line ed v)) (add1 (view-col ed v)))]))
     (values txt (list (cons 0 'status-bar)))]))

;; p 相对文件树根；不在根下（或未设根）则给完整路径。
(define (tree-relative-path st p)
  (define ts (feature-ref st 'tree #f))
  (define root (and ts (tree-root ts)))
  (define cp (simplify-path (path->complete-path p)))
  (cond
    [(not root) (format "~a" p)]
    [else
     (define r (simplify-path (path->complete-path root)))
     (define rp (explode-path r))
     (define qp (explode-path cp))
     (if (and (>= (length qp) (length rp)) (equal? rp (take qp (length rp))))
         (format "~a" (find-relative-path r cp))
         (format "~a" p))]))

;; 资源面板是树：document 是根，view 是子；多个 document 并列。
;; row = (list did vid label depth kind)，kind = 'doc | 'view；doc 行 vid = #f。
;; 折叠状态存 feature 'buffers-fold（hash did -> #t = 收起），默认展开。
(define (buffer-rows st)
  (define ed (state-ed st))
  (define folded (feature-ref st 'buffers-fold (hash)))
  (append*
   (for/list ([did (in-list (document-id-list ed))])
     (define name (document-name ed did))
     (cond
       [(panel-name? st name) '()]
       [else
        (define label (doc-label st did))
        (define vids (document-view-list ed did))
        (define doc-row (list did #f label 0 'doc))
        (cond
          [(hash-has-key? folded did) (list doc-row)]
          [(null? vids) (list doc-row)]
          [else (cons doc-row
                      (for/list ([vid (in-list vids)])
                        (list did vid (view-cursor-label st vid) 1 'view)))])]))))

(define (buffer-items st) (buffer-rows st))

;; 子行（视图）用光标 line:col 区分，不重复 document 名字。
(define (view-cursor-label st vid)
  (define ed (state-ed st))
  (format "~a:~a" (add1 (view-line ed vid)) (add1 (view-col ed vid))))

;; 资源显示名：有文件路径就相对文件树根（工作路径），否则用文档名。
(define (doc-label st did)
  (define m (hash-ref (state-docs st) did #f))
  (define p (and m (doc-meta-path m)))
  (cond [(not p) (document-name (state-ed st) did)]
        [else (tree-relative-path st p)]))

;; 焦点文档 did（用于 buffers 高亮当前文档）。
(define (focused-did* st)
  (define w (state-focus st))
  (define v (and w (layout-wid-vid (state-layout st) w)))
  (and v (view-did (state-ed st) v)))

(define (doc-dirty*? st did)
  (define m (hash-ref (state-docs st) did #f))
  (and m (doc-meta-saved m)
       (not (eq? (doc-meta-saved m) (document-handle (state-ed st) did)))))

(define (buffers-content st v)
  (define rows (buffer-rows st))
  (define folded (feature-ref st 'buffers-fold (hash)))
  (define fdid (focused-did* st))
  (define lines
    (for/list ([r (in-list rows)])
      (match-define (list did vid label depth kind) r)
      (define marker
        (cond
          [(eq? kind 'doc)
           (cond [(null? (document-view-list (state-ed st) did)) "  "]
                 [(hash-has-key? folded did) "▸ "]
                 [else "▾ "])]
          [(layout-has? (state-layout st) vid) "● "]   ; 已显示在窗格里
          [else "· "]))
      (string-append (make-string (* 2 depth) #\space) marker label)))
  (values (string-join lines "\n")
          (for/list ([r (in-list rows)] [i (in-naturals)])
            (define did (car r))
            (define kind (list-ref r 4))
            (cons i (cond [(doc-dirty*? st did) 'buf-dirty]
                          [(eq? kind 'doc)
                           (cond [(eqv? did fdid) 'buf-current]
                                 [(not (doc-meta-path (hash-ref (state-docs st) did #f))) 'buf-untitled]
                                 [else 'buf-file])]
                          [else 'buf-view])))))

;; 已打开文档的路径（文件树用它把「已打开」染成 tree-open）。
(define (open-paths st)
  (for/list ([did (in-list (document-id-list (state-ed st)))]
             #:when (let ([m (hash-ref (state-docs st) did #f)]) (and m (doc-meta-path m))))
    (doc-meta-path (hash-ref (state-docs st) did))))

(define (tree-content st v)
  ;; 目录行末尾加一个 "/"；已经带分隔符（如根路径）就不再加，避免 "//"。
  (define (dir-label s)
    (if (or (zero? (string-length s)) (char=? #\/ (string-ref s (sub1 (string-length s)))))
        s
        (string-append s "/")))
  (define ts (feature-ref st 'tree #f))
  (cond
    [(not ts) (values "" '())]
    [else
     (define rows (tree-rows ts))
     (define opens (open-paths st))
     (define lines
       (for/list ([r (in-list rows)])
         (define name (list-ref r 1))
         (define dir? (list-ref r 2))
         (string-append (make-string (* 2 (list-ref r 3)) #\space)
                        (if dir? (dir-label name) name))))
     (values (string-join lines "\n")
             (for/list ([r (in-list rows)] [i (in-naturals)])
               (define p (car r))
               (define name (list-ref r 1))
               (define dir? (list-ref r 2))
               ;; 光标是普通光标（core 的 cursor 格），不把整行染成选区。
               (cons i (cond
                         [(and (positive? (string-length name)) (char=? #\. (string-ref name 0))) 'tree-hidden]
                         [(and (not dir?) (for/or ([o (in-list opens)]) (equal? (explode-path o) (explode-path p)))) 'tree-open]
                         [dir? 'tree-dir]
                         [else 'tree-file]))))]))

;;; ---------- 刷新 ----------

;; 写回面板 doc：文本变了才 assign（保持光标行）；face 每帧重应用（光标移动也要变色）。
;; render : (st v -> (values text faces))，由注册表提供。
(define (refresh-panel! st name render)
  (define v (panel-vid st name))
  (cond
    [(not v) st]
    [else
     (define ed (state-ed st))
     (define-values (text faces) (render st v))
     (cond
       [(not text) st]
       [else
        (define old-line (view-line ed v))
        (define old-col (view-col ed v))
        (unless (equal? text (view-string ed v))
          (assign! ed v text)
          ;; 保留光标行列（行夹到有效范围，列夹到该行长度）——面板也是普通文档光标。
          (define ls (string-split text "\n"))
          (define ln (if (null? ls) 0 (min old-line (max 0 (sub1 (length ls))))))
          (define lc (if (null? ls) 0 (min old-col (string-length (list-ref ls ln)))))
          (set-point! ed v ln lc))
        (for ([f (in-list faces)]) (face-line! ed (view-did ed v) (car f) (cdr f)))
        st])]))

(define (refresh-tree-cache st)
  (define ts0 (feature-ref st 'tree #f))
  (cond
    [(not ts0) st]
    [else (feature-set st 'tree (tree-ensure ts0))]))

;; 基础面板注册表：prep/render 都在上面定义好后才能构造，所以放这里。
(define base-panel-registry
  (panel-registry
   (list (panel-spec "*status*"  #f status-content)
         (panel-spec "*buffers*" #f buffers-content)
         (panel-spec "*tree*"    refresh-tree-cache tree-content)
         (panel-spec "*input*"   #f #f)
         (panel-spec "*log*"     #f #f))))

;; 遍历注册表：先跑 prep（可更新 feature），再按 render 重建内容（#f = 不重建）。
(define (refresh-panels! st)
  (for/fold ([s st]) ([spec (in-list (panel-registry-specs (state-panels st)))])
    (define s1 (if (panel-spec-prep spec) ((panel-spec-prep spec) s) s))
    (if (panel-spec-render spec)
        (refresh-panel! s1 (panel-spec-name spec) (panel-spec-render spec))
        s1)))
