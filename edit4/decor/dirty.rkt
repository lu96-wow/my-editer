#lang racket

;;; edit4/decor/dirty.rkt —— 脏行 / 层 track 的增量工具（纯）
;;;
;;; 装饰的最小增量单位是「行」：
;;;   · 文本是持久化 track（分块共享），编辑只重建受影响的块；
;;;   · 把扫描结果也缓存成一条 track（行 payload 任意），编辑后只重扫脏行。
;;;
;;;   dirty                 脏区（全脏 | 行集合）—— 显式结构，杜绝 'all 哨兵混入列表运算
;;;   changes->dirty-lines  一次编辑波及的行（新坐标）
;;;   scan-track            整篇扫描成缓存 track
;;;   refresh-layer         按 change 的行区间重扫脏行，其余行结构共享
;;;
;;; 移植自 edit1 的 core/face/line-scan.rkt（只保留这里要用的部分）。

(provide (struct-out dirty) dirty-all dirty-lines dirty-union dirty-all? dirty-ls dirty->lines
         changes->dirty-lines
         scan-track refresh-layer
         track->lines track->string)

(require (except-in racket/list range)
         racket/match
         "../../core/text/base/change.rkt"
         "../../core/text/base/point.rkt"
         "../../core/text/base/range.rkt"
         "../../core/text/base/track.rkt"
         "../../core/text/base/line.rkt")

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

;;; ---------- 缓存 track ----------

;; 整篇扫描：scan : line-index string -> 行局部值。
(define (scan-track text scan)
  (track-of-list
   (for/list ([line (in-list (track->list text))] [i (in-naturals)])
     (scan i line))))

;; 只重扫脏行：把旧层中「编辑波及的结构区间」按 change 的 before→after 行区间替换成
;; 对新文本重扫的结果，其余行由 track 结构共享。
;;
;;   changes : (listof change)      本次编辑（before = 旧层坐标，after = 新文本坐标）
;;   extra   : (listof line-index)  额外内容脏行（新坐标，如活动词所在行）
(define (refresh-layer layer text changes extra scan)
  (define n (track-length text))
  ;; 每个 change → (list old-lo old-hi new-lo new-hi)，含端点（hi 开）。
  (define spans
    (sort
     (for/list ([ch (in-list changes)])
       (define b (change-before ch))
       (define a (change-after ch))
       (list (point-line (range-start b)) (add1 (point-line (range-end b)))
             (point-line (range-start a)) (add1 (point-line (range-end a)))))
     > #:key car))
  ;; 结构替换从右到左：右侧替换不影响左侧的旧层行号。
  (define layer*
    (for/fold ([layer layer]) ([sp (in-list spans)])
      (match-define (list olo ohi nlo nhi) sp)
      (track-splice layer olo ohi
                    (for/list ([line (in-list (track-slice text nlo nhi))]
                               [i (in-naturals nlo)])
                      (scan i line)))))
  (define covered
    (for*/list ([sp (in-list spans)] [i (in-range (third sp) (fourth sp))]) i))
  (for/fold ([layer layer*]) ([ln (in-list (sort (remove-duplicates extra) <))])
    (if (or (>= ln n) (memv ln covered))
        layer
        (track-splice layer ln (add1 ln)
                      (list (scan ln (track-ref text ln)))))))

;;; ---------- 文本 track 便捷读 ----------

(define (track->lines t) (track->list t))
(define (track->string t) (lines->string (track->list t)))
