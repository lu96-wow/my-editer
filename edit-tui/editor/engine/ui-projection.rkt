#lang racket

;;; edit-tui-rebuild/editor/engine/ui-projection.rkt —— UI view 写回 / 增量投影
;;;
;;; 这里只处理“把宿主 / 插件的 UI 投影写进 core view”：
;;;   · 文本 + 整行 face
;;;   · 文本不变时只改变化行的 face
;;;   · 文本变化时做最小字符区间替换
;;;   · 逐字符 face track / face lines
;;;   · UI view 光标
;;;
;;; engine 生命周期 / 查询在 store.rkt；view action 解释在 apply.rkt。

(require racket/string
         "../../../core/editor.rkt"
         "store.rkt")

(provide engine-set-view-content!
         engine-set-view-face-track!
         engine-set-view-face-lines!
         engine-set-view-cursor!
         engine-set-view-lines!)

;;; 写 UI view 的内容（文本 + 每行 face），不碰光标。
;;;
;;; 三种路径：
;;;   1. 没变                       -> no-op
;;;   2. 文本没变，只 face 变        -> 只改变化行的整行 face
;;;   3. 文本变了                   -> 最小文本区间替换 + 重写整组 face
;;;
;;; 3 的文本替换做了 common prefix / suffix 字符 diff；不整篇 set-document，
;;; 不产生新的 UI 历史。face 在文本变化时整组重写，避免行号位移后旧 face
;;; 贴到错误行；selection 更新单独走路径 2。
;;;
;;; #:readonly-prefix n  首行前 n 个字符标成 readonly（输入栏 prompt 前缀）
;;; #:prefix-face face   这 n 个字符用不同 face（只在前缀非空时生效）
(define (common-prefix-length a b)
  (define n (min (string-length a) (string-length b)))
  (let loop ([i 0])
    (cond
      [(>= i n) i]
      [(char=? (string-ref a i) (string-ref b i)) (loop (add1 i))]
      [else i])))

(define (common-suffix-length a b limit)
  (let loop ([i 0])
    (cond
      [(>= i limit) i]
      [(char=? (string-ref a (- (string-length a) 1 i))
               (string-ref b (- (string-length b) 1 i)))
       (loop (add1 i))]
      [else i])))

(define (common-line-prefix a b)
  (define n (min (length a) (length b)))
  (let loop ([i 0])
    (cond
      [(>= i n) i]
      [(equal? (list-ref a i) (list-ref b i)) (loop (add1 i))]
      [else i])))

(define (common-line-suffix a b limit)
  (let loop ([i 0])
    (cond
      [(>= i limit) i]
      [(equal? (list-ref a (- (length a) 1 i))
               (list-ref b (- (length b) 1 i)))
       (loop (add1 i))]
      [else i])))

(define (face-at faces i)
  (if (< i (length faces)) (list-ref faces i) #f))

;; 字符 offset -> point（offset 可等于全文长度）。
(define (offset->point text offset)
  (define n (min (max 0 offset) (string-length text)))
  (let loop ([i 0] [line 0] [col 0])
    (cond
      [(>= i n) (point line col)]
      [(char=? (string-ref text i) #\newline)
       (loop (add1 i) (add1 line) 0)]
      [else (loop (add1 i) line (add1 col))])))

(define (write-ui-faces! b faces)
  (for ([i (in-naturals)] [face (in-list faces)])
    (when face (buffer-face-line! b i face))))

(define (write-ui-prefix! b lines readonly-prefix prefix-face)
  (when (and (pair? lines) (positive? readonly-prefix))
    (define n (min readonly-prefix (string-length (car lines))))
    (define r (range (point 0 0) (point 0 n)))
    (buffer-readonly-range! b r #t)
    (when prefix-face (buffer-face-range! b r prefix-face))))

(define (engine-set-view-content! e vid lines faces
                                  #:readonly-prefix [readonly-prefix 0]
                                  #:prefix-face [prefix-face #f])
  (define v (engine-view-object e vid))
  (cond
    [(not v) #f]
    [else
     (define b (view-buffer v))
     (define prev (hash-ref (engine-ui e) vid #f))
     (define cache (list lines faces readonly-prefix prefix-face))
     (cond
       [(not prev)
        (full-ui-write! e vid b cache lines faces readonly-prefix prefix-face)
        #t]
       [else
        (define prev-lines (list-ref prev 0))
        (define prev-faces (list-ref prev 1))
        (define prev-ro (list-ref prev 2))
        (define prev-prefix (list-ref prev 3))
        (define old-text (view-string v))
        (define new-text (string-join lines "\n"))
        (define text-same? (string=? old-text new-text))
        (define meta-same? (and (= prev-ro readonly-prefix)
                                (equal? prev-prefix prefix-face)))
        (cond
          ;; 1. 完全没变
          [(and text-same? meta-same? (equal? prev-faces faces)) #f]

          ;; 2. 文本没变，只 face 变：只碰变化行的整行 face。
          [(and text-same? meta-same?)
           (define n (length (string-split old-text "\n" #:trim? #f)))
           (for ([i (in-range n)])
             (define old-face (if (< i (length prev-faces))
                                  (list-ref prev-faces i)
                                  #f))
             (define new-face (if (< i (length faces))
                                  (list-ref faces i)
                                  #f))
             (unless (equal? old-face new-face)
               (buffer-face-line! b i new-face)))
           (set-engine-ui! e (hash-set (engine-ui e) vid cache))
           (set-engine-face-track-cache!
            e (hash-remove (engine-face-track-cache e) vid))
           #t]

          ;; 3. 文本变了：最小字符区间替换；UI 历史保持关闭。
          [else
           (define views (buffer-views b))
           (define old-sels (for/list ([vv (in-list views)]) (view-selections vv)))
           (define cp (common-prefix-length old-text new-text))
           (define max-suffix (- (min (string-length old-text) (string-length new-text)) cp))
           (define cs (common-suffix-length old-text new-text max-suffix))
           (define old-end (- (string-length old-text) cs))
           (define new-end (- (string-length new-text) cs))
           (define inserted (substring new-text cp new-end))
           (void (buffer-replace-range! b
                                        (range (offset->point old-text cp)
                                               (offset->point old-text old-end))
                                        inserted))
           (buffer-reset-history! b #f)
           ;; readonly prefix 不属于文本轨：先清再按新内容重设。
           (when (or (positive? prev-ro) (positive? readonly-prefix))
             (buffer-readonly-all! b #f))
           ;; face 只重写变化行：
           ;;   · 公共前缀 / 后缀行文本没变，只在该行 face 变了时更新；
           ;;   · 行数变了，变化块之后全部重写，避免行号位移后旧 face 贴错行。
           (define old-lines (string-split old-text "\n" #:trim? #f))
           (define new-lines* (string-split new-text "\n" #:trim? #f))
           (define lp (common-line-prefix old-lines new-lines*))
           (define lmax (- (min (length old-lines) (length new-lines*)) lp))
           (define ls (common-line-suffix old-lines new-lines* lmax))
           (define n-old (length old-lines))
           (define n-new (length new-lines*))
           (for ([i (in-range n-new)])
             (define update?
               (cond
                 ;; 公共前缀：行号不变，只有 face 变了才写。
                 [(< i lp)
                  (not (equal? (face-at prev-faces i)
                               (face-at faces i)))]
                 ;; 行数不变时，公共后缀行号也不变，同样只在 face 变化时写。
                 [(and (= n-old n-new)
                       (>= i (- n-new ls)))
                  (not (equal? (face-at prev-faces i)
                               (face-at faces i)))]
                 ;; 变化块 / 行数变化后的后缀：整行重写。
                 [else #t]))
             (when update?
               (buffer-face-line! b i (face-at faces i))))
           (write-ui-prefix! b lines readonly-prefix prefix-face)
           ;; 保持旧光标语义：行号 / 列号尽量不动，越界由 view-set-selections! clamp。
           (for ([vv (in-list views)] [sels (in-list old-sels)])
             (view-set-selections! vv sels))
           (set-engine-ui! e (hash-set (engine-ui e) vid cache))
           (set-engine-face-track-cache!
            e (hash-remove (engine-face-track-cache e) vid))
           #t])])]))

(define (full-ui-write! e vid b cache lines faces readonly-prefix prefix-face)
  ;; UI view（filetree / status / input）不是用户可撤销的文档；
  ;; 整篇重写时不记历史，避免每帧/每键积累无用的 document 版本。
  (buffer-reset-history! b #f)
  (buffer-set-document! b (string-join lines "\n"))
  (buffer-face-all! b #f)
  (write-ui-faces! b faces)
  (write-ui-prefix! b lines readonly-prefix prefix-face)
  (set-engine-ui! e (hash-set (engine-ui e) vid cache))
  ;; 内容重写会清空 face 轨；旧的逐字符 face 缓存必须一起失效。
  (set-engine-face-track-cache! e (hash-remove (engine-face-track-cache e) vid)))

;;; ---------- 逐字符 face（编辑器语法高亮 / 括号背景） ----------

;; 一行 face 向量 -> 非 #f 的连续 range。
;; 调用方先用 buffer-face-all! #f 清空整轨，所以只产生“有 face”的 run。
(define (face-line->runs line-no line vec)
  (define n (min (string-length line) (vector-length vec)))
  (let loop ([i 0] [acc '()])
    (cond
      [(>= i n) (reverse acc)]
      [else
       (define f (vector-ref vec i))
       (cond
         [(not f) (loop (add1 i) acc)]
         [else
          (define j (let next ([j (add1 i)])
                      (if (and (< j n) (equal? (vector-ref vec j) f))
                          (next (add1 j))
                          j)))
          (loop j (cons (list (range (point line-no i) (point line-no j)) f)
                        acc))])])))

;; 写一个 view 的逐字符 attribute / face track，不动文本 / 光标 / 历史。
;; face-track : (listof (vectorof (or/c #f symbol? face?)))，与文本行对齐。
;; #:key      : 写回幂等键；同 key 的重复帧不会碰 document revision。
;; #:base-version : face track 对应的 document version；不匹配时拒绝写（CAS）。
;; → 是否真的写了。
(define (engine-set-view-face-track! e vid face-track
                                     #:key [key #f]
                                     #:base-version [base-version #f])
  (define v (engine-view-object e vid))
  (define current-version (and v (buffer-version (view-buffer v))))
  (cond
    [(not v) #f]
    ;; 后台结果可能晚于文本编辑；版本不同就整轨拒绝，绝不把旧 face 贴到新文本。
    [(and base-version (not (equal? base-version current-version))) #f]
    [else
     (define prev (hash-ref (engine-face-track-cache e) vid #f))
     (define changed?
       (or (not prev)
           (if key
               (not (equal? (car prev) key))
               (not (equal? (cdr prev) face-track)))))
     (when changed?
       (define b (view-buffer v))
       (define text-lines (string-split (view-string v) "\n" #:trim? #f))
       (define track (if (vector? face-track) (vector->list face-track) face-track))
       (buffer-face-all! b #f)
       (define runs
         (append*
          (for/list ([line (in-list text-lines)]
                     [i (in-naturals)]
                     [faces (in-list track)])
            (if (vector? faces)
                (face-line->runs i line faces)
                '()))))
       (when (pair? runs) (buffer-face-range-batch! b runs))
       (set-engine-face-track-cache!
        e
        (hash-set (engine-face-track-cache e) vid
                  (cons key face-track))))
     changed?]))

;; 只重写若干行的 face：清掉这些行的旧 face，再写新 run。
;; face-lines : (listof (cons line-no (vectorof (or/c #f face?))))
;; 用于增量着色；不动其他行，也不清整条 face track。
(define (engine-set-view-face-lines! e vid face-lines
                                     #:key [key #f]
                                     #:base-version [base-version #f])
  (define v (engine-view-object e vid))
  (define current-version (and v (buffer-version (view-buffer v))))
  (cond
    [(not v) #f]
    [(and base-version (not (equal? base-version current-version))) #f]
    [else
     (define b (view-buffer v))
     (define text-lines (string-split (view-string v) "\n" #:trim? #f))
     (define n (length text-lines))
     (define fills
       (append*
        (for/list ([entry (in-list face-lines)])
          (define line-no (car entry))
          (define vec (cdr entry))
          (cond
            [(or (not (exact-nonnegative-integer? line-no))
                 (>= line-no n)
                 (not (vector? vec)))
             '()]
            [else
             (define line (list-ref text-lines line-no))
             (define len (string-length line))
             (define clear
               (if (positive? len)
                   (list (list (range (point line-no 0)
                                      (point line-no len))
                               #f))
                   '()))
             (append clear (face-line->runs line-no line vec))]))))
     (when (pair? fills) (buffer-face-range-batch! b fills))
     ;; key 相同就表示这份 face track 已经是最新；cdr 不保留整轨，
     ;; 避免为了局部更新再复制整份大对象。
     (set-engine-face-track-cache!
      e (hash-set (engine-face-track-cache e) vid (cons key #f)))
     (pair? fills)]))

;; 光标单独写：内容同步不应该每帧把用户移动过的光标按回去。
(define (engine-set-view-cursor! e vid line #:column [column 0])
  (define v (engine-view-object e vid))
  (cond
    [(not v) (void)]
    [else
     (define text (view-string v))
     (define n (max 1 (length (string-split text "\n" #:trim? #f))))
     (define l (max 0 (min line (sub1 n))))
     (define c (max 0 column))
     (unless (and (= (view-point-line v) l)
                  (= (view-point-column v) c))
       (view-set-selections! v (selections-one (caret (point l c))))
       (view-ensure! v))]))

;; 兼容旧调用：内容 + 光标一次写完。
(define (engine-set-view-lines! e vid lines faces line
                                #:column [column 0]
                                #:readonly-prefix [readonly-prefix 0]
                                #:prefix-face [prefix-face #f])
  (engine-set-view-content! e vid lines faces
                            #:readonly-prefix readonly-prefix
                            #:prefix-face prefix-face)
  (engine-set-view-cursor! e vid line #:column column))

