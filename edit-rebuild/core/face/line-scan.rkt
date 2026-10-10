#lang racket

;;; edit-rebuild/core/face/line-scan.rkt —— 行局部扫描缓存（纯）
;;;
;;; 高亮插件的最小增量单位是「行」：
;;;   · 文本是持久化 track（分块共享），编辑只重建受影响的块；
;;;   · 把扫描结果也缓存成一条 track（行 payload 任意），编辑后只重扫脏行。
;;;
;;;   dirty                 脏区（全脏 | 行集合）—— 显式结构，杜绝 'all 哨兵混入列表运算
;;;   changes->dirty-lines  一次编辑波及的行（新坐标）
;;;   contiguous-runs       排序去重的行号 → 连续区间（供 track-splice 用）
;;;   scan-track            整篇扫描成缓存 track
;;;   refresh-layer         只重扫脏行，其余行结构共享
;;;   face-runs             一行 face 向量 → 连续同 face 区间（供写回）
;;;
;;; core 边界只给中性结构（change / track）；「什么算一个词」仍留在 lex.rkt。

(require (except-in racket/list range)
         "../../../core/text/base/change.rkt"
         "../../../core/text/base/point.rkt"
         "../../../core/text/base/range.rkt"
         "../../../core/text/base/track.rkt")

(provide (struct-out dirty) dirty-all dirty-lines dirty-union dirty->lines
         changes->dirty-lines contiguous-runs
         scan-track refresh-layer face-runs)

;;; ---------- 脏区 ----------

;; 脏区 = 全脏（all?）或一组行号。显式类型，避免把「全脏」哨兵混进列表运算。
(struct dirty (all? ls) #:transparent)

(define (dirty-all) (dirty #t '()))
(define (dirty-lines lines) (dirty #f (sort (remove-duplicates lines) <)))
(define (dirty-union a b)
  (cond [(dirty-all? a) a]
        [(dirty-all? b) b]
        [else (dirty-lines (append (dirty-ls a) (dirty-ls b)))]))
;; 展开成具体行号，夹到 [0,n)。
(define (dirty->lines d n)
  (cond [(dirty-all? d) (for/list ([i (in-range n)]) i)]
        [else (filter (lambda (i) (< i n)) (dirty-ls d))]))

;;; ---------- 脏行 ----------

;; 一条 change 的 after 区间覆盖的整行（前后都含；删除的零宽 after 也重扫该行）。
(define (change-line-span ch)
  (define r (change-post-range ch))
  (cons (point-line (range-start r)) (point-line (range-end r))))

(define (changes->dirty-lines changes)
  (sort (remove-duplicates
         (append* (for/list ([ch (in-list changes)])
                    (define sp (change-line-span ch))
                    (for/list ([i (in-range (car sp) (add1 (cdr sp)))]) i))))
        <))

;; 排序去重的行号 → 升序连续区间 (start . end)，end 开。
(define (contiguous-runs lines)
  (cond
    [(null? lines) '()]
    [else
     (define-values (runs cur)
       (for/fold ([runs '()] [cur (cons (car lines) (car lines))])
                 ([x (in-list (cdr lines))])
         (if (= x (add1 (cdr cur)))
             (values runs (cons (car cur) x))
             (values (cons (cons (car cur) (add1 (cdr cur))) runs)
                     (cons x x)))))
     (reverse (cons (cons (car cur) (add1 (cdr cur))) runs))]))

;;; ---------- 缓存 track ----------

;; 整篇扫描：scan : line-index string -> 行局部值。
(define (scan-track text scan)
  (track-of-list
   (for/list ([line (in-list (track->list text))] [i (in-naturals)])
     (scan i line))))

;; 只重扫脏行：把 [lo,hi) 的缓存行换成对新文本重扫的结果，其余行由 track 共享。
(define (refresh-layer layer text dirty-lines scan)
  (for/fold ([layer layer]) ([run (in-list (contiguous-runs dirty-lines))])
    (define lo (car run))
    (define hi (cdr run))
    (track-splice layer lo hi
                  (for/list ([line (in-list (track-slice text lo hi))]
                             [i (in-naturals lo)])
                    (scan i line)))))

;;; ---------- 行 face 向量 → 区间 ----------

;; vec : (vectorof face)，face 可为 #f。→ (listof (list start end face))，face 非 #f。
(define (face-runs vec)
  (define n (vector-length vec))
  (let loop ([i 0] [acc '()])
    (cond
      [(>= i n) (reverse acc)]
      [else
       (define f (vector-ref vec i))
       (define j (let next ([j (add1 i)])
                   (if (and (< j n) (equal? (vector-ref vec j) f)) (next (add1 j)) j)))
       (loop j (if f (cons (list i j f) acc) acc))])))
