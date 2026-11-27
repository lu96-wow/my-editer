#lang racket

;;; edit-tui/lang/racket/base/edit.rkt —— 语言层的中性编辑描述（纯）
;;;
;;; core 的 change 有精确点/区间；但 lang/ 不依赖 core。
;;; 这里只保留增量需要的“行区间”：
;;;
;;;   line-edit = old [start,end) -> new [start,end)
;;;
;;; start/end 都是 0-based 行号，end 开区间。
;;; 行级词法 / 高亮 / 顶层 form 缓存都用它。

(provide (struct-out line-edit)
         line-edit?
         edits->dirty-lines
         edit-spans
         splice-vector
         splice-vector-preserve
         split-lines)

(struct line-edit
  (old-start old-end new-start new-end)
  #:transparent)

;; 新坐标下受影响的整行。纯删除（new-start = new-end）也要重扫删除位置所在行。
(define (edits->dirty-lines edits [line-count #f])
  (define lines
    (sort
     (remove-duplicates
      (append*
       (for/list ([e (in-list edits)])
         (cond
           [(= (line-edit-new-start e) (line-edit-new-end e))
            (list (line-edit-new-start e))]
           [else
            (for/list ([ln (in-range (line-edit-new-start e)
                                     (line-edit-new-end e))])
              ln)]))))
     <))
  (if line-count
      (for/list ([ln (in-list lines)] #:when (< ln line-count)) ln)
      lines))

;; 从右到左处理：右侧替换不影响左侧旧坐标。
(define (edit-spans edits)
  (sort
   (for/list ([e (in-list edits)])
     (list (line-edit-old-start e)
           (line-edit-old-end e)
           (line-edit-new-start e)
           (line-edit-new-end e)))
   > #:key car))

;; 把旧向量 [old-start, old-end) 换成 new-count 个 #f。
(define (splice-vector v old-start old-end new-count)
  (define n (vector-length v))
  (define lo (max 0 (min old-start n)))
  (define hi (max lo (min old-end n)))
  (vector-append
   (vector-copy v 0 lo)
   (make-vector (max 0 new-count) #f)
   (vector-copy v hi n)))

;; 行数不变时保留旧值作为“收敛参考”；行数变化时填 #f，强制继续推进。
(define (splice-vector-preserve v old-start old-end new-count)
  (define n (vector-length v))
  (define lo (max 0 (min old-start n)))
  (define hi (max lo (min old-end n)))
  (define old-count (- hi lo))
  (define k (max 0 new-count))
  ;; 一次分配 + 两次 copy，避免 vector-append 的临时向量；
  ;; 行数不变时保留旧值作为收敛参考。
  (define out (make-vector (+ lo k (- n hi)) #f))
  (vector-copy! out 0 v 0 lo)
  (when (= old-count k)
    (vector-copy! out lo v lo hi))
  (vector-copy! out (+ lo k) v hi n)
  out)

;; 按 \n 切行，语义与 (string-split text "\n" #:trim? #f) 一致：
;; 空串 → '()；保留空行和行尾空段。
;; 手写 O(n) 扫描，避免 regexp-split 在大文件上的开销。
(define (split-lines text)
  (define n (string-length text))
  (cond
    [(zero? n) '()]
    [else
     (let loop ([i 0] [start 0] [acc '()])
       (cond
         [(= i n) (reverse (cons (substring text start i) acc))]
         [(char=? (string-ref text i) #\newline)
          (loop (add1 i) (add1 i) (cons (substring text start i) acc))]
         [else (loop (add1 i) start acc)]))]))
