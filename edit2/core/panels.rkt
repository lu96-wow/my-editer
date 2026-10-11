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
 region-members region-side region-size
 panel-doc-name parse-region
 panel-specs panel-name? panel-vid panel-name
 refresh-panels! buffer-items buffer-rows tree-relative-path
 tree-init tree-ensure tree-rows tree-toggle-dir tree-expand-dir tree-parent-dir
 panel-line panel-line-at)

(require racket/path
         "state.rkt" "adapter.rkt" "fs.rkt" "layout.rkt")

;;; ---------- 区域（共享同一块面板的多个成员，互斥显示） ----------

(struct region (id side size members) #:transparent)

;; 面板 id（symbol）↔ 文档名（string）。
(define (panel-doc-name id) (if (symbol? id) (format "*~a*" id) id))

;; 配置数据 (id side size (member ...)) → region 结构；成员映射到文档名。
(define (parse-region d)
  (match-define (list id side size members) d)
  (region id side size (map panel-doc-name members)))

;;; ---------- 面板清单（core 认识的 panel 名；config 选启用哪些） ----------

(define panel-specs
  '("*tree*" "*buffers*" "*status*" "*log*" "*help*"))

(define (panel-name? name)
  (and (string? name) (and (member name panel-specs) #t)))

(define (panel-vid st name)
  (define ed (state-ed st))
  (for/first ([vid (in-list (view-id-list ed))]
              #:when (equal? name (view-document-name ed vid)))
    vid))

(define (panel-name st vid)
  (define ed (state-ed st))
  (define n (and vid (view-document-name ed vid)))
  (and (panel-name? n) n))

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

;; root / 展开集 / 目录快照缓存。**没有游标**——选择就是面板文档的光标。
(struct tree (root expanded children) #:transparent)

(define (tree-init root) (tree (simplify-path (path->complete-path root)) (hash) (hash)))

(define (tree-ensure ts)
  (define dirs (cons (tree-root ts) (hash-keys (tree-expanded ts))))
  (define ch
    (for/fold ([ch (tree-children ts)]) ([d (in-list dirs)] #:unless (hash-has-key? ch d))
      (hash-set ch d (with-handlers ([exn:fail? (lambda (_) '())]) (fs-read-dir d)))))
  (struct-copy tree ts [children ch]))

;; 可见行：(path name dir? depth)
(define (tree-rows ts)
  (define (walk dir depth)
    (append*
     (for/list ([e (in-list (hash-ref (tree-children ts) dir '()))])
       (define p (car e)) (define d? (cdr e))
       (cons (list p (path->string (file-name-from-path p)) d? depth)
             (if (and d? (hash-has-key? (tree-expanded ts) p)) (walk p (add1 depth)) '())))))
  (walk (tree-root ts) 0))

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

(define (panel-text+faces st name v)
  (case (string->symbol name)
    [(*status*)  (status-content st)]
    [(*buffers*) (buffers-content st v)]
    [(*tree*)    (tree-content st v)]
    [else (values #f '())]))

(define (status-content st)
  (define p (state-input st))
  (define w (state-focus st))
  (define v (and w (layout-wid-vid (state-layout st) w)))   ; focus 是 wid；取显示的 vid
  (cond
    [(placing? (feature-ref st 'placing #f))
     (define target (if v (doc-label st (view-did (state-ed st) v)) "(空窗口)"))
     (values (format " 选择目标窗口: ~a   Tab / M-n 切换   Enter 替换   Esc 取消" target) '())]
    [(prompt? p) (values (string-append " " (prompt-label p) (prompt-text p)) '())]
    [else
     (define ed (state-ed st))
     (define txt
       (cond
         [(not v) " [空窗口]  C-w 分屏  C-q 退出"]
         [else
          (define did (view-did ed v))
          (define m (hash-ref (state-docs st) did #f))
          (define pth (and m (doc-meta-path m)))
          (define name (if pth (tree-relative-path st pth) (view-document-name ed v)))
          (define dirty (and m (doc-meta-saved m)
                             (not (eq? (doc-meta-saved m) (document-handle ed did)))))
          (format " ~a~a   ~a:~a" name (if dirty " *" "")
                  (add1 (view-line ed v)) (add1 (view-col ed v)))]))
     (values txt '())]))

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
       [(panel-name? name) '()]
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

(define (buffers-content st v)
  (define rows (buffer-rows st))
  (define folded (feature-ref st 'buffers-fold (hash)))
  (define cursor (if v (view-line (state-ed st) v) 0))
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
            (cons i (cond [(= i cursor) 'tree-cursor]
                          [(eq? (list-ref r 4) 'doc) 'buffers-doc]
                          [else 'buffers-view])))))

(define (tree-content st v)
  (define ts (feature-ref st 'tree #f))
  (cond
    [(not ts) (values "" '())]
    [else
     (define rows (tree-rows ts))
     (define cursor (if v (view-line (state-ed st) v) 0))
     (define lines
       (for/list ([r (in-list rows)])
         (string-append (make-string (* 2 (list-ref r 3)) #\space)
                        (if (list-ref r 2) "▸ " "  ")
                        (list-ref r 1))))
     (values (string-join lines "\n")
             (for/list ([r (in-list rows)] [i (in-naturals)])
               (cons i (cond [(= i cursor) 'tree-cursor]
                             [(list-ref r 2) 'tree-dir]
                             [else 'tree-file]))))]))

;;; ---------- 刷新 ----------

;; 写回面板 doc：文本变了才 assign（保持光标行）；face 每帧重应用（光标移动也要变色）。
(define (refresh-panel! st name)
  (define v (panel-vid st name))
  (cond
    [(not v) st]
    [else
     (define ed (state-ed st))
     (define-values (text faces) (panel-text+faces st name v))
     (cond
       [(not text) st]
       [else
        (define old-line (view-line ed v))
        (unless (equal? text (view-string ed v))
          (assign! ed v text)
          (define n (max 0 (sub1 (length (string-split text "\n")))))
          (set-point! ed v (min old-line n) 0))
        (for ([f (in-list faces)]) (face-line! ed (view-did ed v) (car f) (cdr f)))
        st])]))

(define (refresh-tree-cache st)
  (define ts0 (feature-ref st 'tree #f))
  (cond
    [(not ts0) st]
    [else (feature-set st 'tree (tree-ensure ts0))]))

(define (refresh-panels! st)
  (define st1 (refresh-tree-cache st))
  (for/fold ([s st1]) ([name (in-list '("*status*" "*buffers*" "*tree*"))])
    (refresh-panel! s name)))
