#lang racket

(require "cursor.rkt" "buffer.rkt" "window.rkt"
         "properties.rkt" "overlay.rkt" rackunit)

;;; render.rkt —— 显示引擎
;;;
;;; 每行渲染 = 合并 props-runs 与 overlay-runs 的边界，逐段合成 face。
;;; redisplay 是增量：比对 tick，用 dirty 决定哪些行重算，其余复用。
;;;
;;; 三级局部更新：
;;;   1. tick 相同 → 整窗不动
;;;   2. dirty 行范围外 → 复用缓存
;;;   3. 行数变化时尾部整体平移，shift 偏移复用

(provide
 (struct-out glyph)
 (struct-out rendered-line)
 render-line
 redisplay
 rendered-line->string)

;;; ---------- 表示 ----------

(struct glyph (ch face) #:transparent)
;; face : immutable hash

(struct rendered-line (glyphs) #:transparent)
;; glyphs : (vectorof glyph)

(define empty-plist (hash))

;;; ---------- face 合成 ----------

(define (hash-merge-into base extras)
  (for/fold ([h base]) ([(k v) (in-hash extras)])
    (hash-set h k v)))

;; overlay 的控制键：进入 plist 但不属于 face
(define overlay-control-keys '(priority evaporate))

(define (face-plist p)
  (for/hash ([(k v) (in-hash p)] #:unless (memq k overlay-control-keys))
    (values k v)))

;; 给定位置的 props plist 和 overlay 列表（按 priority 降序）。
;; props 视作 priority 0 且在同优先级中最后合并：
;;   priority <= 0 的 overlay 在 props 之下，priority > 0 的在 props 之上。
(define (compute-face p-plist ovs)
  (define-values (below above)
    (partition (lambda (ov) (<= (overlay-priority ov) 0)) ovs))
  (define f0 (for/fold ([f (hash)]) ([ov (in-list (reverse below))])
               (hash-merge-into f (face-plist (overlay-plist ov)))))
  (define f1 (hash-merge-into f0 (face-plist p-plist)))
  (for/fold ([f f1]) ([ov (in-list (reverse above))])
    (hash-merge-into f (face-plist (overlay-plist ov)))))

;;; ---------- 单行渲染 ----------

(define (render-line b i)
  (define text (buffer-line-ref b i))
  (define n (string-length text))
  (define p-runs (props-runs (buffer-properties b) i n))
  (define o-runs (overlay-table-runs (buffer-overlays b)
                                     (buffer-markers b)
                                     i n))
  ;; 收集所有边界点
  (define all-points
    (sort (remove-duplicates
           (append (list 0 n)
                   (append-map (lambda (seg) (list (car seg) (cadr seg))) p-runs)
                   (append-map (lambda (seg) (list (car seg) (cadr seg))) o-runs)))
          <))
  ;; 逐段合成
  (define glyphs (make-vector n #f))
  (for ([a (in-list (drop-right all-points 1))]
        [b (in-list (rest all-points))])
    (define p-plist
      (or (for/first ([seg (in-list p-runs)]
                      #:when (and (<= (car seg) a) (> (cadr seg) a)))
            (caddr seg))
          empty-plist))
    (define ovs
      (or (for/first ([seg (in-list o-runs)]
                      #:when (and (<= (car seg) a) (> (cadr seg) a)))
            (caddr seg))
          '()))
    (define face (compute-face p-plist ovs))
    (for ([j (in-range a b)])
      (vector-set! glyphs j (glyph (string-ref text j) face))))
  (rendered-line glyphs))

;;; ---------- 缓存计算 ----------

(define (compute-cache w b)
  (define d (buffer-dirty b))
  (define old-cache (window-render-cache w))
  (define n (buffer-line-count b))
  (cond
    ;; 无 dirty（例如手动 tick 变化）：全量重算
    [(not d)
     (for/vector ([i (in-range n)]) (render-line b i))]
    [else
     (define first (dirty-desc-first-line d))
     (define last  (dirty-desc-last-line  d))
     (define shift (- (dirty-desc-new-count d) (dirty-desc-old-count d)))
     (for/vector ([i (in-range n)])
       (define old-i
         (cond
           [(< i first) i]                        ; 头部：未移位
           [(<= i last) #f]                       ; 脏区：重算
           [else (- i shift)]))                   ; 尾部：按 shift 平移
       (cond
         [(not old-i) (render-line b i)]
         [(and old-cache
               (>= old-i 0)
               (< old-i (vector-length old-cache)))
          (vector-ref old-cache old-i)]
         [else (render-line b i)]))]))

;;; ---------- redisplay ----------

(define (redisplay w)
  (define b (window-buffer w))
  (define t (buffer-tick b))
  (cond
    [(and (window-render-cache w) (= (window-last-tick w) t)) w] ; 第一级：已渲染且 tick 相同
    [else
     (define new-cache (compute-cache w b))       ; 第二、三级：dirty 局部重算
     (window-set-render-cache
      (window-set-last-tick
       (window-set-buffer w (buffer-clean b))
       t)
      new-cache)]))

;;; ---------- 辅助（测试用）----------

(define (rendered-line->string rl)
  (list->string (for/list ([g (in-vector (rendered-line-glyphs rl))])
                  (glyph-ch g))))

;;; ---------- 测试 ----------

(module+ test
  (define b0 (buffer-open "hello\nworld"))
  (define w0 (window-open b0))

  ;; 首次渲染
  (define w1 (redisplay w0))
  (define cache1 (window-render-cache w1))
  (check-equal? (vector-length cache1) 2)
  (check-equal? (rendered-line->string (vector-ref cache1 0)) "hello")
  (check-equal? (rendered-line->string (vector-ref cache1 1)) "world")
  (check-equal? (window-last-tick w1) 0)

  ;; 无编辑：tick 相同，redisplay 原样返回（eq?）
  (check-eq? w1 (redisplay w1))

  ;; 一次编辑（当前行替换字符）
  (define b1 (buffer-insert b0 #\X))
  (define w2 (redisplay (window-set-buffer w1 b1)))
  (define cache2 (window-render-cache w2))
  (check-equal? (rendered-line->string (vector-ref cache2 0)) "Xhello")
  (check-equal? (rendered-line->string (vector-ref cache2 1)) "world")
  ;; 第 1 行应复用（eq?）——dirty 只覆盖第 0 行
  (check-eq? (vector-ref cache1 1) (vector-ref cache2 1))

  ;; newline：行数 +1，尾部平移复用
  (define b2 (buffer-newline b0))                  ; "\nhello\nworld"
  (define w3 (redisplay (window-set-buffer w1 b2)))
  (define cache3 (window-render-cache w3))
  (check-equal? (vector-length cache3) 3)
  (check-equal? (rendered-line->string (vector-ref cache3 0)) "")
  (check-equal? (rendered-line->string (vector-ref cache3 1)) "hello")
  (check-equal? (rendered-line->string (vector-ref cache3 2)) "world")

  ;; backspace-merge：行数 -1，尾部平移复用
  (define b3 (buffer-backspace (buffer-home (buffer-down b0))))
  ;; "helloworld"，1 行
  (define w4 (redisplay (window-set-buffer w1 b3)))
  (define cache4 (window-render-cache w4))
  (check-equal? (vector-length cache4) 1)
  (check-equal? (rendered-line->string (vector-ref cache4 0)) "helloworld")

  ;; 属性渲染
  (define b4 (buffer-put-text-property b0 0 1 4 'face 'bold))
  (define w5 (redisplay (window-set-buffer w1 b4)))
  (define cache5 (window-render-cache w5))
  (define line0 (vector-ref cache5 0))
  (define glyphs0 (rendered-line-glyphs line0))
  (check-equal? (glyph-ch (vector-ref glyphs0 0)) #\h)
  (check-equal? (glyph-face (vector-ref glyphs0 0)) (hash))
  (check-equal? (glyph-face (vector-ref glyphs0 1)) (hash 'face 'bold))
  (check-equal? (glyph-face (vector-ref glyphs0 2)) (hash 'face 'bold))
  (check-equal? (glyph-face (vector-ref glyphs0 3)) (hash 'face 'bold))
  (check-equal? (glyph-face (vector-ref glyphs0 4)) (hash))

  ;; overlay 渲染：region 覆盖 [1, 4)
  (define-values (b5 oid) (buffer-make-overlay b0 (cursor 0 1) (cursor 0 4)
                                                (hash 'face 'region)))
  (define w6 (redisplay (window-set-buffer w1 b5)))
  (define line0b (vector-ref (window-render-cache w6) 0))
  (define glyphs0b (rendered-line-glyphs line0b))
  (check-equal? (glyph-face (vector-ref glyphs0b 0)) (hash))
  (check-equal? (glyph-face (vector-ref glyphs0b 1)) (hash 'face 'region))
  (check-equal? (glyph-face (vector-ref glyphs0b 3)) (hash 'face 'region))
  (check-equal? (glyph-face (vector-ref glyphs0b 4)) (hash))

  ;; overlay priority 覆盖 props
  (define b6 (buffer-put-text-property b5 0 1 4 'face 'bold))
  (define-values (b7 oid2) (buffer-make-overlay b6 (cursor 0 2) (cursor 0 3)
                                                 (hash 'face 'highlight 'priority 5)))
  (define w7 (redisplay (window-set-buffer w1 b7)))
  (define glyphs0c (rendered-line-glyphs (vector-ref (window-render-cache w7) 0)))
  (check-equal? (glyph-face (vector-ref glyphs0c 1)) (hash 'face 'bold))
  (check-equal? (glyph-face (vector-ref glyphs0c 2)) (hash 'face 'highlight))
  (check-equal? (glyph-face (vector-ref glyphs0c 3)) (hash 'face 'bold))

  (displayln "render.rkt: all tests passed"))