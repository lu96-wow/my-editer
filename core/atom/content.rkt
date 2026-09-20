#lang racket

(require "point.rkt" "lines.rkt" "edit.rkt" rackunit)

;;; atom/content.rkt —— 行向量文本存储
;;;
;;; 职责只有一件：**存文本、施加编辑**。不含光标、不含属性/标记。
;;;
;;; 编辑的唯一单位是 edit-desc（见 atom/edit.rkt）；原语只有一个 content-apply。
;;; 插入/删除/换行/合并都只是「造一条 edit-desc」。退格/删除需要看文本才能定出
;;; 被删区间，故提供两个**纯函数**先算出 desc，再由 content-apply 施加。

(provide
 (struct-out content)
 content-empty
 content-of-string
 content-of-lines
 content->string
 content->lines
 content-line-count
 content-line-ref
 content-check
 content-clamp-point
 content-line-length
 content-point->offset
 content-offset->point
 content-apply
 content-backspace-desc
 content-delete-desc)

;;; ---------- 数据 ----------

(struct content (lines) #:transparent)
;; lines : (vectorof string)   至少一行，每行是纯文本（不含 \n）

;;; ---------- 构造 / 投影 ----------

(define (content-empty) (content (vector "")))

(define (content-of-lines lines)
  (unless (and (pair? lines) (andmap string? lines))
    (error 'content-of-lines "expect non-empty list of strings, got ~a" lines))
  (content (list->vector lines)))

(define (content-of-string s)
  (unless (string? s) (error 'content-of-string "expect string, got ~a" s))
  (content (list->vector (string->lines s))))

(define (content->lines c)     (vector->list (content-lines c)))
(define (content->string c)    (lines->string (content->lines c)))
(define (content-line-count c) (vector-length (content-lines c)))
(define (content-line-ref c i) (vector-ref (content-lines c) i))

;; 行数 ≥ 1（空文本也是 1 个空行）。给诊断/测试用。
(define (content-check c)
  (define n (content-line-count c))
  (unless (>= n 1) (error 'content-check "content must have >= 1 line"))
  (for ([line (in-vector (content-lines c))])
    (unless (string? line) (error 'content-check "non-string line: ~a" line)))
  c)

;;; ---------- 位置夹紧 ----------
;; 越界位置有唯一合法解释 → 夹到合法域。行 ∈ [0, 行数)，列 ≤ 该行长。
;; 唯一实现在 point-clamp；这里只把「行数 + 行长」两个投影喂给它。
(define (content-clamp-point c p)
  (point-clamp p (content-line-count c)
               (lambda (l) (string-length (content-line-ref c l)))))

(define (content-line-length c line)
  (define n (content-line-count c))
  (define l (max 0 (min line (sub1 n))))
  (string-length (content-line-ref c l)))

;;; ---------- 行列 ↔ 绝对偏移 ----------
;; 偏移以 content->string 为坐标系：行内字符各占 1，行间 \n 占 1；末行无尾 \n。
;; 因此第 i 行行首偏移 = Σ_{j<i} (行长_j + 1)，最大偏移 = 字符串长度。
;; 输入先夹紧，故两个方向对任意输入都有定义，且互为逆（在合法域内）。

(define (content-point->offset c p)
  (define q (content-clamp-point c p))
  (+ (for/sum ([i (in-range (point-line q))])
       (+ (string-length (content-line-ref c i)) 1))
     (point-col q)))

(define (content-offset->point c off)
  (define n (content-line-count c))
  (define max-off
    (sub1 (for/sum ([i (in-range n)]) (+ (string-length (content-line-ref c i)) 1))))
  (define o (max 0 (min off max-off)))
  (let loop ([i 0] [rest o])
    (define len (string-length (content-line-ref c i)))
    (cond
      [(and (< i (sub1 n)) (> rest len)) (loop (add1 i) (- rest (add1 len)))]
      [else (point i (min rest len))])))

;;; ---------- 施加：唯一原语 ----------

;; 施加一条 edit-desc。端点先夹紧；夹紧后仍反向（start > end）没有合法解释 → 报错。
;; 返回 (values 新 content 生效的 desc)：生效 desc 里的坐标是**夹紧后**的值，
;; 上层（属性/标记/账本）一律用它，不要用传入的原始 desc。
(define (content-apply c d)
  (define n (content-line-count c))
  (define lines (content-lines c))
  (define s (content-clamp-point c (edit-desc-start d)))
  (define e (content-clamp-point c (edit-desc-end d)))
  (when (point<? e s)
    (error 'content-apply "编辑区间反向: ~a..~a" s e))
  (define sl (point-line s)) (define sc (point-col s))
  (define el (point-line e)) (define ec (point-col e))
  (define text (edit-desc-new-text d))
  ;; 新文本拆行：k 段。k=0（纯删除）时两行拼成一行。
  (define new-lines (string->lines text))
  (define k (length new-lines))
  (define head (substring (vector-ref lines sl) 0 sc))
  (define tail (substring (vector-ref lines el) ec
                          (string-length (vector-ref lines el))))
  (define inserted (max 1 k))                              ; k=0 时合并出的 1 行
  (define v* (make-vector (- (+ n inserted) (+ (- el sl) 1)) #f))
  (vector-copy! v* 0 lines 0 sl)
  (cond
    [(zero? k) (vector-set! v* sl (string-append head tail))]
    [(= k 1)   (vector-set! v* sl (string-append head (car new-lines) tail))]
    [else
     (vector-set! v* sl (string-append head (car new-lines)))
     (for ([i (in-range 1 (sub1 k))])
       (vector-set! v* (+ sl i) (list-ref new-lines i)))
     (vector-set! v* (+ sl (sub1 k))
                  (string-append (list-ref new-lines (sub1 k)) tail))])
  (vector-copy! v* (+ sl inserted) lines (add1 el) n)
  (values (content v*) (edit-desc s e text)))

;;; ---------- 退格 / 删除：先算 desc（纯），不直接施加 ----------

(define (content-backspace-desc c p)
  (define q (content-clamp-point c p))
  (define l (point-line q))
  (define o (point-col q))
  (cond
    [(> o 0) (edit-desc (point l (sub1 o)) q "")]                ; 删前一个字符
    [(> l 0) (edit-desc (point (sub1 l) (string-length (content-line-ref c (sub1 l))))
                        (point l 0) "")]                          ; 与上一行合并
    [else #f]))

(define (content-delete-desc c p)
  (define q (content-clamp-point c p))
  (define l (point-line q))
  (define o (point-col q))
  (cond
    [(< o (string-length (content-line-ref c l)))                ; 删该处字符
     (edit-desc q (point l (add1 o)) "")]
    [(< l (sub1 (content-line-count c)))                         ; 与下一行合并
     (edit-desc q (point (add1 l) 0) "")]
    [else #f]))

;;; ---------- 测试 ----------

(module+ test
  (define (apply* c d) (let-values ([(c* _) (content-apply c d)]) c*))

  (check-equal? (content->string (content-empty)) "")
  (check-equal? (content->string (content-of-string "hello\nworld")) "hello\nworld")
  (check-equal? (content->lines (content-of-string "hello\nworld")) '("hello" "world"))
  (check-equal? (content-line-count (content-of-string "a\nb\n")) 3)   ; 尾换行保留空行

  (define c0 (content-of-string "hello\nworld"))
  (check-equal? (content-line-length c0 0) 5)
  (check-equal? (content-line-length c0 9) 5)
  (check-equal? (content-point->offset c0 (point 0 0)) 0)
  (check-equal? (content-point->offset c0 (point 1 0)) 6)
  (check-equal? (content-offset->point c0 6) (point 1 0))
  (for ([off (in-range 0 12)])
    (check-equal? (content-point->offset c0 (content-offset->point c0 off)) off))

  (check-equal? (content->string (apply* c0 (edit-desc (point 0 0) (point 0 0) "X")))
                "Xhello\nworld")
  (define c1 (content-of-string "abcd\nefgh\nijkl"))
  (check-equal? (content->string (apply* c1 (edit-desc (point 0 1) (point 2 1) "XY\nZ")))
                "aXY\nZjkl")
  (check-equal? (let-values ([(c* d*) (content-apply (content-of-string "abc")
                                                     (edit-desc (point 0 1) (point 0 99) ""))])
                  (list (content->string c*) d*))
                (list "a" (edit-desc (point 0 1) (point 0 3) "")))
  (check-exn exn:fail?
             (lambda () (content-apply (content-of-string "abcdef")
                                       (edit-desc (point 0 3) (point 0 1) ""))))

  (check-equal? (content-backspace-desc c0 (point 0 2)) (edit-desc (point 0 1) (point 0 2) ""))
  (check-false (content-backspace-desc c0 (point 0 0)))
  (check-equal? (content-delete-desc c0 (point 0 0)) (edit-desc (point 0 0) (point 0 1) ""))
  (check-false (content-delete-desc c0 (point 1 5)))

  (displayln "content.rkt: all tests passed"))
