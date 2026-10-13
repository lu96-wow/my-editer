#lang racket

;;; edit4/plugins/sync/transform.rkt —— 纯：文本 ↔ 文本（token 级映射）
;;;
;;; 只把「代码位置」的符号 token 按词表替换；字符串 / 注释 / 数字 / 空白原样。
;;; 跨行状态 = (block-depth . in-string?)，与编辑器的换行无关（按 "\n" 切行再拼回）。
;;;
;;; translate/edits 同时产出编辑表（同号行内的列替换），供 view 同步映射光标。

(provide translate translate/edits map-caret)

(require racket/list racket/string
         "../../decor/lex.rkt"
         "mapping.rkt")

;;; ---------- 扫描：代码位置的符号范围 ----------

(define (scan-symbols st line)
  (define n (string-length line))
  (define (ref i) (string-ref line i))
  (let loop ([i 0] [block (car st)] [in-str? (cdr st)] [acc '()])
    (cond
      [(>= i n) (values (cons block in-str?) (reverse acc))]
      [(positive? block)
       (cond
         [(and (char=? (ref i) #\|) (< (add1 i) n) (char=? (ref (add1 i)) #\#))
          (loop (+ i 2) (sub1 block) #f acc)]
         [(and (char=? (ref i) #\#) (< (add1 i) n) (char=? (ref (add1 i)) #\|))
          (loop (+ i 2) (add1 block) #f acc)]
         [else (loop (add1 i) block #f acc)])]
      [in-str?
       (cond
         [(and (char=? (ref i) #\\) (< (add1 i) n)) (loop (+ i 2) block #t acc)]
         [(char=? (ref i) #\") (loop (add1 i) block #f acc)]
         [else (loop (add1 i) block #t acc)])]
      [(and (char=? (ref i) #\#) (< (add1 i) n) (char=? (ref (add1 i)) #\|))
       (loop (+ i 2) (add1 block) #f acc)]
      [(char=? (ref i) #\;) (values (cons block #f) (reverse acc))]  ; 行注释：本行剩余忽略
      [(char=? (ref i) #\") (loop (add1 i) block #t acc)]
      [(and (char=? (ref i) #\#) (< (add1 i) n) (char=? (ref (add1 i)) #\\))
       (loop (min n (+ i 3)) block #f acc)]
      [(ident-start? (ref i))
       (define j (let next ([j (add1 i)])
                   (if (and (< j n) (ident-char? (ref j))) (next (add1 j)) j)))
       (loop j block #f (cons (cons i j) acc))]
      [else (loop (add1 i) block #f acc)])))

;;; ---------- 重写一行 + 记录编辑 ----------

;; → (values new-line (listof (list line src0 src1 dst0 dst1)))
(define (rewrite-line line spans table ln)
  (define out (open-output-string))
  (define pos 0)
  (define dst 0)
  (define edits '())
  (for ([sp (in-list spans)])
    (define s0 (car sp))
    (define s1 (cdr sp))
    (define tok (substring line s0 s1))
    (define pair (assoc tok table))
    (define rep (if pair (cdr pair) tok))
    (define gap (substring line pos s0))
    (write-string gap out)
    (set! dst (+ dst (string-length gap)))
    (write-string rep out)
    (unless (equal? rep tok)
      (set! edits (cons (list ln s0 s1 dst (+ dst (string-length rep))) edits)))
    (set! dst (+ dst (string-length rep)))
    (set! pos s1))
  (write-string (substring line pos) out)
  (values (get-output-string out) (reverse edits)))

;;; ---------- 对外 ----------

;; 按 \n 切行，保留末尾空行（string-split 会丢掉它）。
(define (split-lines s)
  (let loop ([start 0] [i 0] [acc '()])
    (cond
      [(= i (string-length s)) (reverse (cons (substring s start i) acc))]
      [(char=? #\newline (string-ref s i)) (loop (add1 i) (add1 i) (cons (substring s start i) acc))]
      [else (loop start (add1 i) acc)])))

;; translate/edits : mapping dir text -> (values text (listof edit))
(define (translate/edits m dir text)
  (define table (dir-table m dir))
  (define-values (rev-lines edits _st)
    (for/fold ([ls '()] [es '()] [st (cons 0 #f)])
              ([line (in-list (split-lines text))]
               [ln (in-naturals)])
      (define-values (st* spans) (scan-symbols st line))
      (define-values (new-line ed) (rewrite-line line spans table ln))
      (values (cons new-line ls) (append ed es) st*)))
  (values (string-join (reverse rev-lines) "\n") edits))

(define (translate m dir text)
  (define-values (out _edits) (translate/edits m dir text))
  out)

;; 源点 (line . col) → 目标点（同号行）。edits 的 dst 是绝对列。
(define (map-caret edits pt)
  (define ln (car pt))
  (define col (cdr pt))
  (define es (filter (lambda (e) (= (car e) ln)) edits))
  (define inside (for/first ([e (in-list es)]
                             #:when (and (< (list-ref e 1) col) (< col (list-ref e 2)))) e))
  (cons ln
        (cond
          [inside (let ([e inside])
                    (min (list-ref e 4) (+ (list-ref e 3) (- col (list-ref e 1)))))]
          [else (+ col (for/sum ([e (in-list es)] #:when (<= (list-ref e 2) col))
                         (- (- (list-ref e 4) (list-ref e 3))
                            (- (list-ref e 2) (list-ref e 1)))))])))
