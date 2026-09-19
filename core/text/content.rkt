#lang racket

(require "point.rkt" rackunit)

;;; content.rkt —— 行向量文本存储
;;;
;;; 职责只有一件：**存文本、施加编辑**。不含光标、不含「当前位置」、不含属性/标记。
;;;
;;; 编辑的唯一单位是 edit-desc（一个 splice）：
;;;   (edit-desc start end new-text)   ; start/end 是 point，全部「操作前坐标」
;;; 语义：新文本 = before(start) + new-text + after(end)。
;;;
;;; 原语只有一个：content-apply。插入/删除/换行/合并都只是「造一条 edit-desc」。
;;; 退格/删除需要看文本才能定出被删区间，故提供两个**纯函数**先算出 desc
;;; （content-backspace-desc / content-delete-desc），再由 content-apply 施加——
;;; 「算一次编辑」与「施加一次编辑」分开，是这一层的核心分工。

(provide
 (struct-out content)
 (struct-out edit-desc)
 make-content
 content-of-string
 content-of-lines
 string->lines
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
 content-delete-desc
 edit-desc-map-position
 edit-desc-after-position
 edit-desc-inverse)

;;; ---------- 数据 ----------

(struct content (lines) #:transparent)
;; lines : (vectorof string)   至少一行，每行是纯文本（不含 \n）

(struct edit-desc (start end new-text) #:transparent)
;; start / end : point     被替换的半开区间 [start, end)（操作前坐标）
;; new-text    : string    取代该区间的文本（可含 \n）

;;; ---------- 构造 / 投影 ----------

(define (make-content) (content (vector "")))

(define (content-of-lines lines)
  (unless (and (pair? lines) (andmap string? lines))
    (error 'content-of-lines "expect non-empty list of strings, got ~a" lines))
  (content (list->vector lines)))

;; 把字符串按行拆开（统一行尾）：\n、\r\n、孤立 \r 都算一个换行。
;; 结果至少一行；"a\n" => '("a" "")（保留尾部空行）。
(define (string->lines s)
  (define ls (string-split (regexp-replace* #rx"\r\n?" s "\n") "\n" #:trim? #f))
  (if (null? ls) (list "") ls))

(define (content-of-string s)
  (unless (string? s) (error 'content-of-string "expect string, got ~a" s))
  (content (list->vector (string->lines s))))

(define (content->lines c)     (vector->list (content-lines c)))
(define (content->string c)    (string-join (content->lines c) "\n"))
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
;; 位置来自调用方；这里只回答「该删哪一段」。删除范围为空 → #f（无操作）。

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

;;; ---------- desc 代数（位置如何随一次编辑移动）----------
;; 这三个是 marker / properties / overlay 共用的唯一调整机制。全部只认 point。

;; 编辑前位置 p → 编辑后位置；返回 point 或 #f（#f = p 落在被删区间内，已不存在）。
(define (edit-desc-map-position d p)
  (define s (edit-desc-start d))
  (define e (edit-desc-end d))
  (define sl (point-line s)) (define sc (point-col s))
  (define el (point-line e)) (define ec (point-col e))
  (define l (point-line p)) (define c (point-col p))
  (define new-lines (string->lines (edit-desc-new-text d)))
  (define k (length new-lines))
  (define last-len (if (zero? k) 0 (string-length (last new-lines))))
  (define delta (- k (- el sl) 1))            ; 行数变化：k - (el-sl+1)
  (cond
    [(or (pos<? l c sl sc) (pos=? l c sl sc)) (point l c)]   ; 起点及之前不动
    [(pos<? l c el ec) #f]                                    ; 落在被删区间内
    [else                                                     ; 在 end 之后
     (cond
       [(= l el)
        (cond
          [(zero? k) (point sl (+ sc (- c ec)))]              ; 纯删除：接回起点之后
          [(= k 1)   (point sl (+ sc last-len (- c ec)))]     ; 单行插入：含起点列
          [else      (point (+ sl (sub1 k)) (+ last-len (- c ec)))])]
       [else (point (+ l delta) c)])]))

;; 插入文本之后的点（'after' 语义 / 逆编辑的终点 / 光标推进落点）。
(define (edit-desc-after-position d)
  (define s (edit-desc-start d))
  (define new-lines (string->lines (edit-desc-new-text d)))
  (define k (length new-lines))
  (cond
    [(zero? k) (point (point-line s) (point-col s))]                    ; 纯删除 → 回到起点
    [(= k 1)   (point (point-line s) (+ (point-col s) (string-length (car new-lines))))]
    [else      (point (+ (point-line s) (sub1 k)) (string-length (last new-lines)))]))

;; 逆编辑：抵消 d 的那次编辑。用「d 生效后的新坐标系」表示。
;;   · 区间 = [d.start, d 插入文本之后)
;;   · 文本 = d 删掉的旧文本（调用方传入——edit-desc 不含旧文本）
(define (edit-desc-inverse d old-text)
  (edit-desc (edit-desc-start d) (edit-desc-after-position d) old-text))

;;; ---------- 测试 ----------

(module+ test
  (define (apply* c d) (let-values ([(c* _) (content-apply c d)]) c*))

  ;; 构造 / 投影
  (check-equal? (content->string (make-content)) "")
  (check-equal? (content->string (content-of-string "hello\nworld")) "hello\nworld")
  (check-equal? (content->lines (content-of-string "hello\nworld")) '("hello" "world"))
  (check-equal? (content-line-count (content-of-string "a\nb\n")) 3)   ; 尾换行保留空行
  ;; 行尾归一：\r\n / \r → \n
  (check-equal? (content->lines (content-of-string "a\r\nb\rc")) '("a" "b" "c"))

  (define c0 (content-of-string "hello\nworld"))

  ;; 行长度 / 行列 ↔ 偏移（坐标系 = content->string）
  (check-equal? (content-line-length c0 0) 5)
  (check-equal? (content-line-length c0 9) 5)                    ; 行越界夹紧
  (check-equal? (content-point->offset c0 (point 0 0)) 0)
  (check-equal? (content-point->offset c0 (point 0 5)) 5)        ; 行尾 = 换行前
  (check-equal? (content-point->offset c0 (point 1 0)) 6)
  (check-equal? (content-point->offset c0 (point 1 5)) 11)
  (check-equal? (content-point->offset c0 (point 9 9)) 11)       ; 越界先夹紧
  (check-equal? (content-offset->point c0 0) (point 0 0))
  (check-equal? (content-offset->point c0 5) (point 0 5))
  (check-equal? (content-offset->point c0 6) (point 1 0))
  (check-equal? (content-offset->point c0 11) (point 1 5))
  (check-equal? (content-offset->point c0 99) (point 1 5))      ; 夹紧
  ;; 互为逆（合法域内）
  (for ([off (in-range 0 12)])
    (check-equal? (content-point->offset c0 (content-offset->point c0 off)) off))

  ;; 插入（start = end）
  (check-equal? (content->string (apply* c0 (edit-desc (point 0 0) (point 0 0) "X")))
                "Xhello\nworld")
  (check-equal? (content->string (apply* c0 (edit-desc (point 0 2) (point 0 2) "X")))
                "heXllo\nworld")

  ;; 换行 / 多行插入
  (check-equal? (content->string (apply* c0 (edit-desc (point 0 2) (point 0 2) "\n")))
                "he\nllo\nworld")
  (check-equal? (content->string (apply* c0 (edit-desc (point 0 0) (point 0 0) "X\nY")))
                "X\nYhello\nworld")

  ;; 跨行删除 + 多行插入（splice 的一般形）
  (define c1 (content-of-string "abcd\nefgh\nijkl"))
  (check-equal? (content->string (apply* c1 (edit-desc (point 0 1) (point 2 1) "XY\nZ")))
                "aXY\nZjkl")

  ;; content-apply 返回**生效**（夹紧后）的 desc
  (check-equal? (let-values ([(c* d*) (content-apply (content-of-string "abc")
                                                     (edit-desc (point 0 1) (point 0 99) ""))])
                  (list (content->string c*) d*))
                (list "a" (edit-desc (point 0 1) (point 0 3) "")))
  ;; 反向区间 → 报错（无唯一合法解释）
  (check-exn exn:fail?
             (lambda () (content-apply (content-of-string "abcdef")
                                       (edit-desc (point 0 3) (point 0 1) ""))))

  ;; 退格 / 删除：先算 desc，再施加
  (check-equal? (content-backspace-desc c0 (point 0 2)) (edit-desc (point 0 1) (point 0 2) ""))
  (check-equal? (content-backspace-desc c0 (point 1 0))
                (edit-desc (point 0 5) (point 1 0) ""))              ; 行合并
  (check-false (content-backspace-desc c0 (point 0 0)))
  (check-equal? (content-delete-desc c0 (point 0 0)) (edit-desc (point 0 0) (point 0 1) ""))
  (check-equal? (content-delete-desc c0 (point 0 5)) (edit-desc (point 0 5) (point 1 0) ""))
  (check-false (content-delete-desc c0 (point 1 5)))
  (check-equal? (content->string (apply* c0 (content-backspace-desc c0 (point 1 0))))
                "helloworld")

  ;; desc 代数：位置映射
  (define d-sp (edit-desc (point 0 1) (point 2 1) "XY\nZ"))
  (check-equal? (edit-desc-map-position d-sp (point 0 0)) (point 0 0))
  (check-equal? (edit-desc-map-position d-sp (point 0 1)) (point 0 1))   ; 起点
  (check-false (edit-desc-map-position d-sp (point 0 2)))               ; 被删
  (check-false (edit-desc-map-position d-sp (point 1 0)))               ; 被删
  (check-equal? (edit-desc-map-position d-sp (point 2 1)) (point 1 1))  ; = end
  (check-equal? (edit-desc-map-position d-sp (point 2 3)) (point 1 3))  ; 同行 end 之后

  ;; after-position
  (check-equal? (edit-desc-after-position d-sp) (point 1 1))
  (check-equal? (edit-desc-after-position (edit-desc (point 0 3) (point 0 3) "XY")) (point 0 5))
  (check-equal? (edit-desc-after-position (edit-desc (point 2 4) (point 2 4) "中")) (point 2 5))
  (check-equal? (edit-desc-after-position (edit-desc (point 0 1) (point 0 3) "")) (point 0 1))

  ;; 逆编辑（纯代数）
  (check-equal? (edit-desc-inverse (edit-desc (point 0 2) (point 0 5) "XY") "cde")
                (edit-desc (point 0 2) (point 0 4) "cde"))
  (check-equal? (edit-desc-inverse (edit-desc (point 1 0) (point 2 3) "") "l1\nl2")
                (edit-desc (point 1 0) (point 1 0) "l1\nl2"))
  (check-equal? (edit-desc-inverse (edit-desc (point 0 0) (point 0 0) "X") "")
                (edit-desc (point 0 0) (point 0 1) ""))

  (displayln "content.rkt: all tests passed"))
