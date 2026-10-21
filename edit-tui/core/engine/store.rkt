#lang racket

;;; edit-tui-rebuild/engine/store.rkt —— core buffer / view 的唯一拥有者（骨架层）
;;;
;;; 纯 State 只存 id；engine 存真正可变句柄。
;;; 命令 / step 不碰 engine，只产生 action；runtime 解释 action 时写 engine。
;;;
;;; 这是「骨架」的一部分（不依赖 app / runtime）；runtime 用它的可变句柄，
;;; 插件通过 core/skeleton.rkt 拿到只读查询 + 写 UI view 的入口。

(require racket/match
         "../../../core/editor.rkt"
         "action.rkt")

(provide (struct-out engine)
         make-engine
         engine-view-object
         engine-create-buffer! engine-create-view!
         engine-remove-view! engine-remove-doc!
         engine-view-text engine-doc-text engine-doc-version
         engine-view-point-line engine-view-point-column
         engine-set-view-lines!
         engine-apply-view-action!)

(struct engine (docs views ui) #:mutable)
;; ui : vid -> (cons lines faces)：上次写进 core view 的内容。
;; 用来做「写回幂等」——内容没变就不重建 document（否则每帧都换 document、
;; 让 render cache 失效，filetree 上千行时一帧几十毫秒）。

(define (make-engine)
  (engine (hash) (hash) (hash)))

(define (engine-doc-buffer e did)
  (hash-ref (engine-docs e) did #f))

(define (engine-view-object e vid)
  (hash-ref (engine-views e) vid #f))

(define (engine-create-buffer! e did name text)
  (define b (make-buffer text name))
  (set-engine-docs! e (hash-set (engine-docs e) did b))
  b)

(define (engine-create-view! e vid did)
  (define b (engine-doc-buffer e did))
  (unless b (error 'engine-create-view! "doc 不存在：~a" did))
  (define v (buffer-add-view! b 1 1))
  (set-engine-views! e (hash-set (engine-views e) vid v))
  v)

(define (engine-remove-view! e vid)
  (define v (engine-view-object e vid))
  (when v
    (buffer-close-view! (view-buffer v) v)
    (set-engine-views! e (hash-remove (engine-views e) vid))
    (set-engine-ui! e (hash-remove (engine-ui e) vid)))
  (void))

(define (engine-remove-doc! e did)
  (define b (engine-doc-buffer e did))
  (when b
    (define vids
      (for/list ([(vid v) (in-hash (engine-views e))]
                 #:when (eq? (view-buffer v) b))
        vid))
    (for ([vid (in-list vids)]) (engine-remove-view! e vid))
    (buffer-close! b)
    (set-engine-docs! e (hash-remove (engine-docs e) did)))
  (void))

(define (engine-view-text e vid)
  (define v (engine-view-object e vid))
  (and v (view-string v)))

(define (engine-doc-text e did)
  (define b (engine-doc-buffer e did))
  (and b (buffer-string b)))

(define (engine-doc-version e did)
  (define b (engine-doc-buffer e did))
  (and b (buffer-version b)))

(define (engine-view-point-line e vid)
  (define v (engine-view-object e vid))
  (and v (view-point-line v)))

(define (engine-view-point-column e vid)
  (define v (engine-view-object e vid))
  (and v (view-point-column v)))


;;; 整篇写一个 UI view：文本 + 每行 face + 光标行。
;;;
;;; #:readonly-prefix n  首行前 n 个字符标成 readonly（输入栏 prompt 前缀）
;;; #:prefix-face face   这 n 个字符用不同 face（只在前缀非空时生效）
(define (engine-set-view-lines! e vid lines faces line
                                #:column [column 0]
                                #:readonly-prefix [readonly-prefix 0]
                                #:prefix-face [prefix-face #f])
  (define v (engine-view-object e vid))
  (cond
    [(not v) (void)]
    [else
     (define prev (hash-ref (engine-ui e) vid #f))
     (define cache (list lines faces readonly-prefix prefix-face))
     (define content-changed? (or (not prev) (not (equal? prev cache))))
     (when content-changed?
       (define b (view-buffer v))
       ;; UI view（filetree / status / input）不是用户可撤销的文档；
       ;; 整篇重写时不记历史，避免每帧/每键积累无用的 document 版本。
       (buffer-reset-history! b #f)
       (buffer-set-document! b (string-join lines "\n"))
       (buffer-face-all! b #f)
       (for ([i (in-naturals)] [face (in-list faces)])
         (when face (buffer-face-line! b i face)))
       ;; prompt 前缀：只读 + 单独 face（光标 / 编辑只作用于后面可输部分）
       (when (and (pair? lines) (positive? readonly-prefix))
         (define n (min readonly-prefix (string-length (car lines))))
         (define r (range (point 0 0) (point 0 n)))
         (buffer-readonly-range! b r #t)
         (when prefix-face (buffer-face-range! b r prefix-face)))
       (set-engine-ui! e (hash-set (engine-ui e) vid cache)))
     ;; 光标只在真的变了时才写（避免每帧重设 selections / ensure）
     (define n (max 1 (length lines)))
     (define l (max 0 (min line (sub1 n))))
     (define c (max 0 column))
     (unless (and (= (view-point-line v) l)
                  (= (view-point-column v) c))
       (view-set-selections! v (selections-one (caret (point l c))))
       (view-ensure! v))]))

(define (nav-fn dir)
  (case dir
    [(left) view-left!]
    [(right) view-right!]
    [(up) view-up!]
    [(down) view-down!]
    [(home) view-home!]
    [(end) view-end!]
    [else #f]))

;; nav data: dir | (list dir extend?)
(define (apply-nav! v data)
  (match data
    [(list dir extend?)
     (define f (nav-fn dir))
     (unless f (error 'engine-apply-view-action! "未知方向：~a" dir))
     (f v extend?)]
    [dir
     (define f (nav-fn dir))
     (unless f (error 'engine-apply-view-action! "未知方向：~a" dir))
     (f v)]))

;; 翻页：按当前 viewport 高度滚一屏。
(define (page-lines v)
  (max 1 (sub1 (view-height v))))

;; 整屏：光标跟着走一屏（像 vim / less），不是只滚视口
(define (apply-scroll! v which)
  (case which
    [(page-up)   (for ([i (in-range (page-lines v))]) (view-up! v))]
    [(page-down) (for ([i (in-range (page-lines v))]) (view-down! v))]
    [else (view-scroll! v which)]))

;; 删到行尾（vim 的 C-k）。已在行尾时删掉换行，拼下一行。
(define (kill-line! v)
  (define b (view-buffer v))
  (define l (view-point-line v))
  (define c (view-point-column v))
  (define cur (buffer-line b l))
  (define len (and cur (string-length cur)))
  (cond
    [(not len) (void)]
    [(< c len)
     (buffer-replace-range! b (range (point l c) (point l len)) "")]
    [(buffer-line b (add1 l))
     (buffer-replace-range! b (range (point l c) (point (add1 l) 0)) "")]
    [else (void)]))

;; 鼠标点落在文档空白处：view-screen-position->point 返回 #f，
;; 这时取最近的有效位置（点击在可见区上方 -> 起点，否则 -> 可见区末尾）。
(define (view-point-at-or-nearest v row col)
  (define-values (line c) (view-screen-position->point v row col))
  (cond
    [line (point line c)]
    [else
     ;; 行越界：先夹到最近的有效行（上方 -> 可见区起点，否则 -> 可见区末行），
     ;; 再用该行的屏幕位置重新映射列，列仍由 viewport 夹到行尾。
     (define r (view-visible-range v))
     (define target (if (< row 0) (range-start r) (range-end r)))
     (define target-line (point-line target))
     (define-values (sr _sc)
       (view-point->screen-position v (point target-line 0)))
     (cond
       [(not sr) target]
       [else
        (define-values (l c*) (view-screen-position->point v sr col))
        (if l (point l c*) target)])]))

(define (engine-apply-view-action! e action)
  (define vid (view-action-view-id action))
  (define v (engine-view-object e vid))
  (unless v (error 'engine-apply-view-action! "view 不存在：~a" vid))
  (case (view-action-kind action)
    [(insert)
     ;; action 里是原始 UTF-8 bytes；document 是字符串，这里解一次
     (buffer-edit! (view-buffer v) v
                   (op-type (bytes->string/utf-8 (view-action-data action))))]
    [(paste)
     (buffer-edit! (view-buffer v) v
                   (op-paste (bytes->string/utf-8 (view-action-data action))))]
    [(backspace)
     (buffer-edit! (view-buffer v) v (op-backspace))]
    [(delete)
     (buffer-edit! (view-buffer v) v (op-delete))]
    [(kill-line)
     (kill-line! v)]
    [(nav)
     (apply-nav! v (view-action-data action))]
    [(point)
     (match-define (list r c) (view-action-data action))
     (view-set-point! v (view-point-at-or-nearest v r c))]
    [(select)
     (view-set-selections! v (view-action-data action))]
    [(scroll)
     (apply-scroll! v (view-action-data action))]
    [(ensure)
     (view-ensure! v)]
    [(undo) (buffer-undo! (view-buffer v))]
    [(redo) (buffer-redo! (view-buffer v))]
    [else (error 'engine-apply-view-action! "未知 view action：~a" action)])
  (void))
