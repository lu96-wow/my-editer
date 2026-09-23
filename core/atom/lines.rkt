#lang racket

(require rackunit)

;;; atom/lines.rkt —— 文本行拆分（换行归一）
;;;
;;; 这是「字符串 ↔ 行序列」的**唯一**约定，被 content 存储、edit-desc 代数、
;;; attrs 继承共同依赖，所以单独抽成原子，避免各层各拆一套。

(provide string->lines lines->string string-line-geom string-line-count string-last-line-length)

;; 把字符串按行拆开（统一行尾）：\n、\r\n、孤立 \r 都算一个换行。
;; 结果至少一行；"a\n" => '("a" "")（保留尾部空行）。
(define (string->lines s)
  (define ls (string-split (regexp-replace* #rx"\r\n?" s "\n") "\n" #:trim? #f))
  (if (null? ls) (list "") ls))

;; string->lines 的逆：行序列用 \n 拼回。
(define (lines->string ls) (string-join ls "\n"))

;;; ---------- 行几何（不分配行表） ----------
;;; edit-desc 位置代数只需「拆成几行」「末行多长」，不需要真的把行表建出来。
;;; 每次都 string->lines（正则 + split + 分配）在热路径（每个端点 × 每条 desc）
;;; 代价过高；下面是同语义的纯扫描，零分配。

;; 一次扫描同时给出 (values 行数 末行长度)。行尾统一：\n / \r\n / \r。
(define (string-line-geom s)
  (define n (string-length s))
  (let loop ([i 0] [start 0] [k 1])
    (cond
      [(>= i n) (values k (- n start))]
      [else
       (define c (string-ref s i))
       (cond
         [(char=? c #\newline) (loop (add1 i) (add1 i) (add1 k))]
         [(char=? c #\return)
          (define j (if (and (< (add1 i) n) (char=? (string-ref s (add1 i)) #\newline))
                        (+ i 2) (add1 i)))
          (loop j j (add1 k))]
         [else (loop (add1 i) start k)])])))

;; 行数（≥ 1）：与 (length (string->lines s)) 一致。
(define (string-line-count s)
  (let-values ([(k _) (string-line-geom s)]) k))

;; 末行长度（字符数）：与 (string-length (last (string->lines s))) 一致。
(define (string-last-line-length s)
  (let-values ([( _ len) (string-line-geom s)]) len))

;;; ---------- 测试 ----------

(module+ test
  ;; 换行归一（\n / \r\n / 孤立 \r）；尾换行保留空行
  (check-equal? (string->lines "a\nb") '("a" "b"))
  (check-equal? (string->lines "a\n") '("a" ""))
  (check-equal? (string->lines "") '(""))
  (check-equal? (string->lines "a\r\nb\rc") '("a" "b" "c"))
  ;; 逆：lines->string 拼回
  (check-equal? (lines->string '("a" "b")) "a\nb")
  (check-equal? (lines->string (string->lines "a\r\nb")) "a\nb")

  ;; 行几何：与 string->lines 的 length / last 一致（\n / \r\n / \r 都要归一）
  (for ([s (in-list '("" "a" "a\nb" "a\n" "\n" "a\r\nb\rc" "a\r" "\r\n" "中\n文"))])
    (check-equal? (string-line-count s) (length (string->lines s)))
    (check-equal? (string-last-line-length s) (string-length (last (string->lines s)))))
  (displayln "lines.rkt: all tests passed"))
