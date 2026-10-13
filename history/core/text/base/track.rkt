#lang racket

;;; track.rkt —— 轨：分块持久化行序列
;;;
;;; 一条 track = 若干「行」的顺序序列。先分行，以**行**为操作单位，再按固定行数分块。
;;; 每块行数在**创建时**传入（默认 512），存进 track，之后的编辑沿用。
;;;
;;; 行的 payload 对 track 不透明：
;;;     文本轨   行 = string
;;;     属性轨   行 = vector
;;; 所以「文本」和「属性」是同一种东西，只是行 payload 不同（见 line.rkt）。
;;;
;;; 持久化：一次编辑只重建受影响的块；未改动的块在旧值 / 新值之间**按指针共享**。
;;; 旧版本因此天然保留 —— undo/redo 只需换回旧 track 值，不必求逆。
;;;
;;; 层级词汇：
;;;     格 cell   —— 一行内的最小单位（字符 / 符号）        见 line.rkt
;;;     行 line   —— 一行的 payload（string / vector）      见 line.rkt
;;;     轨 track  —— 分块行序列（本文件）
;;;     块 chunk  —— track 内部的分块单位（默认 512 行）

(provide
 ;; ---------- 类型 / 参数 ----------
 (struct-out track)
 default-chunk-lines

 ;; ---------- 构造 ----------
 track-empty
 track-of-list

 ;; ---------- 读 ----------
 track->list
 track-ref

 ;; ---------- 写（区间） ----------
 track-slice
 track-splice
 track-insert
 track-delete
 track-append

 ;; ---------- 映射 ----------
 track-map
 track-map-range
 track-rewrite

 ;; ---------- 切割 ----------
 track-split
 track-take
 track-drop

 ;; ---------- 校验 ----------
 track-check)
;; 注：track-length / track-max / track-chunks / track-starts 由 struct-out 透出。

;;; ---------- 数据 ----------

(define default-chunk-lines 512)

(struct chunk (lines) #:transparent)
;; lines : (vectorof any/c)，长度 1..max；一行一个 payload

(struct track (chunks starts length max) #:transparent)
;; chunks : (vectorof chunk)   按行序；可为空（空 track）
;; starts : (vectorof nat)     starts[i] = 第 i 块首行的全局行号；与 chunks 等长
;; length : nat                总行数
;; max    : nat                每块行数上界

;;; ---------- 内部 ----------

(define (chunk-nlines c) (vector-length (chunk-lines c)))

(define (chunks->track chunks max)
  (define cv (list->vector chunks))
  (define nb (vector-length cv))
  (define starts (make-vector nb 0))
  (for ([i (in-range 1 nb)])
    (vector-set! starts i (+ (vector-ref starts (sub1 i))
                             (chunk-nlines (vector-ref cv (sub1 i))))))
  (define n (if (zero? nb)
                0
                (+ (vector-ref starts (sub1 nb)) (chunk-nlines (vector-ref cv (sub1 nb))))))
  (track cv starts n max))

(define (chunk-append a b)
  (chunk (vector-append (chunk-lines a) (chunk-lines b))))

;; 相邻块合并：合并后 ≤ max 且其中至少一块 < min。
(define (normalize chunks max min)
  (for/fold ([acc '()] #:result (reverse acc)) ([c (in-list chunks)])
    (cond
      [(null? acc) (list c)]
      [else
       (define p (car acc))
       (if (and (<= (+ (chunk-nlines p) (chunk-nlines c)) max)
                (or (< (chunk-nlines p) min) (< (chunk-nlines c) min)))
           (cons (chunk-append p c) (cdr acc))
           (cons c acc))])))

(define (partition-lines lines max)
  (define v (list->vector lines))
  (define n (vector-length v))
  (for/list ([s (in-range 0 n max)])
    (chunk (vector-copy v s (min n (+ s max))))))

;; 最大的 i 使 starts[i] ≤ k（块非空时）
(define (chunk-index-of starts k)
  (let loop ([lo 0] [hi (sub1 (vector-length starts))])
    (if (>= lo hi)
        lo
        (let ([mid (quotient (+ lo hi 1) 2)])
          (if (<= (vector-ref starts mid) k) (loop mid hi) (loop lo (sub1 mid)))))))

;;; ---------- 构造 / 投影 ----------

(define (track-empty [chunk-lines default-chunk-lines])
  (chunks->track '() (max 1 chunk-lines)))

(define (track-of-list lines [chunk-lines default-chunk-lines])
  (define m (max 1 chunk-lines))
  (define mn (max 1 (quotient m 2)))
  (chunks->track (normalize (partition-lines lines m) m mn) m))

(define (track->list t)
  (append* (for/list ([c (in-vector (track-chunks t))])
             (vector->list (chunk-lines c)))))

;;; ---------- 读 ----------

(define (track-ref t i)
  (unless (and (exact-nonnegative-integer? i) (< i (track-length t)))
    (error 'track-ref "行号越界: ~a（共 ~a 行）" i (track-length t)))
  (define idx (chunk-index-of (track-starts t) i))
  (vector-ref (chunk-lines (vector-ref (track-chunks t) idx))
              (- i (vector-ref (track-starts t) idx))))

;; 半开行区间 [s,e) 的行表；越界先夹紧。
(define (track-slice t s e)
  (define s* (max 0 (min s (track-length t))))
  (define e* (max s* (min e (track-length t))))
  (define out '())
  (for ([c (in-vector (track-chunks t))]
        [base (in-vector (track-starts t))])
    (define lo (max 0 (- s* base)))
    (define hi (min (chunk-nlines c) (- e* base)))
    (when (< lo hi)
      (for ([j (in-range lo hi)])
        (set! out (cons (vector-ref (chunk-lines c) j) out)))))
  (reverse out))

;;; ---------- 切分 / 拼接（共享块） ----------

(define (track-split t k)
  (define k* (max 0 (min k (track-length t))))
  (cond
    [(= k* 0) (values (chunks->track '() (track-max t)) t)]
    [(= k* (track-length t)) (values t (chunks->track '() (track-max t)))]
    [else
     (define chunks (track-chunks t))
     (define starts (track-starts t))
     (define nb (vector-length chunks))
     (define idx (chunk-index-of starts k*))
     (define local (- k* (vector-ref starts idx)))
     (define c (vector-ref chunks idx))
     (define left-chunks
       (append (for/list ([x (in-vector chunks 0 idx)]) x)
               (if (zero? local)
                   '()
                   (list (chunk (vector-copy (chunk-lines c) 0 local))))))
     (define right-chunks
       (append (if (= local (chunk-nlines c))
                   '()
                   (list (chunk (vector-copy (chunk-lines c) local))))
               (for/list ([x (in-vector chunks (add1 idx) nb)]) x)))
     (values (chunks->track left-chunks (track-max t))
             (chunks->track right-chunks (track-max t)))]))

(define (track-append a b)
  ;; 两轨可能由不同 chunk-lines 创建：取较大者为结果上界，
  ;; 否则较小 max 的轨会容纳不下另一轨本已合法的块（块 > max）。
  (define m (max (track-max a) (track-max b)))
  (define mn (max 1 (quotient m 2)))
  (chunks->track (normalize (append (vector->list (track-chunks a))
                                    (vector->list (track-chunks b)))
                            m mn)
                 m))

(define (track-take t k) (let-values ([(l _) (track-split t k)]) l))
(define (track-drop t k) (let-values ([(_ r) (track-split t k)]) r))

;;; ---------- 写：范围重写（行区间） ----------

;; 把 [s,e) 行整体换成 new-lines（可长可短，空 = 删除行）。
(define (track-splice t s e new-lines)
  (define s* (max 0 (min s (track-length t))))
  (define e* (max s* (min e (track-length t))))
  (cond
    [(and (= s* e*) (null? new-lines)) t]
    [else
     (define-values (l rest) (track-split t s*))
     (define-values (_mid rr) (track-split rest (- e* s*)))
     (define mid (track-of-list new-lines (track-max t)))
     (track-append (track-append l mid) rr)]))

(define (track-insert t i lines) (track-splice t i i lines))
(define (track-delete t s e) (track-splice t s e '()))

;;; ---------- 映射 ----------

;; 对每一行施加 f（行 payload → 行 payload），行数不变。
(define (track-map t f)
  (chunks->track
   (for/list ([c (in-vector (track-chunks t))])
     (chunk (vector-map f (chunk-lines c))))
   (track-max t)))

;; 只对 [s,e) 的行施加 f。
(define (track-map-range t s e f)
  (define s* (max 0 (min s (track-length t))))
  (define e* (max s* (min e (track-length t))))
  (track-splice t s* e* (map f (track-slice t s* e*))))

;; 重写单行（常用糖）。
(define (track-rewrite t i f) (track-map-range t i (add1 i) f))

;;; ---------- 校验 ----------

(define (track-check t)
  (define cv (track-chunks t))
  (define nb (vector-length cv))
  (define starts (track-starts t))
  (define max (track-max t))
  (unless (= nb (vector-length starts)) (error 'track-check "starts 与 chunks 长度不符"))
  (define sum 0)
  (for ([c (in-vector cv)] [i (in-range nb)])
    (define s (chunk-nlines c))
    (unless (>= s 1) (error 'track-check "出现空块"))
    (unless (<= s max) (error 'track-check "块 ~a 超过上界 ~a" s max))
    (unless (= (vector-ref starts i) sum) (error 'track-check "starts 不一致"))
    (set! sum (+ sum s)))
  (unless (= sum (track-length t)) (error 'track-check "length 与块和不符"))
  t)
