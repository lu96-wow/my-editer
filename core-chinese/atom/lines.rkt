#lang racket

(require rackunit)

;;; atom/lines.rkt —— 文本行拆分（换行归一）
;;;
;;; 这是「字符串 ↔ 行序列」的**唯一**约定，被 内容 存储、编辑-描述 代数、
;;; 属性集 继承共同依赖，所以单独抽成原子，避免各层各拆一套。

(provide 字符串->行列表 行列表->字符串 字符串-行-几何 字符串-行-数量 字符串-末-行-长度)

;; 把字符串按行拆开（统一行尾）：\n、\r\n、孤立 \r 都算一个换行。
;; 结果至少一行；"a\n" => '("a" "")（保留尾部空行）。
(define (字符串->行列表 s)
  (define ls (string-split (regexp-replace* #rx"\r\n?" s "\n") "\n" #:trim? #f))
  (if (null? ls) (list "") ls))

;; 字符串->行列表 的逆：行序列用 \n 拼回。
(define (行列表->字符串 ls) (string-join ls "\n"))

;;; ---------- 行几何（不分配行表） ----------
;;; 编辑-描述 位置代数只需「拆成几行」「末行多长」，不需要真的把行表建出来。
;;; 每次都 字符串->行列表（正则 + 分割 + 分配）在热路径（每个端点 × 每条 描述）
;;; 代价过高；下面是同语义的纯扫描，零分配。

;; 一次扫描同时给出 (values 行数 末行长度)。行尾统一：\n / \r\n / \r。
(define (字符串-行-几何 s)
  (define n (string-length s))
  (let loop ([i 0] [起点 0] [k 1])
    (cond
      [(>= i n) (values k (- n 起点))]
      [else
       (define c (string-ref s i))
       (cond
         [(char=? c #\newline) (loop (add1 i) (add1 i) (add1 k))]
         [(char=? c #\return)
          (define j (if (and (< (add1 i) n) (char=? (string-ref s (add1 i)) #\newline))
                        (+ i 2) (add1 i)))
          (loop j j (add1 k))]
         [else (loop (add1 i) 起点 k)])])))

;; 行数（≥ 1）：与 (length (字符串->行列表 s)) 一致。
(define (字符串-行-数量 s)
  (let-values ([(k _) (字符串-行-几何 s)]) k))

;; 末行长度（字符数）：与 (string-length (last (字符串->行列表 s))) 一致。
(define (字符串-末-行-长度 s)
  (let-values ([( _ 长度) (字符串-行-几何 s)]) 长度))

;;; ---------- 测试 ----------

(module+ test
  ;; 换行归一（\n / \r\n / 孤立 \r）；尾换行保留空行
  (check-equal? (字符串->行列表 "a\nb") '("a" "b"))
  (check-equal? (字符串->行列表 "a\n") '("a" ""))
  (check-equal? (字符串->行列表 "") '(""))
  (check-equal? (字符串->行列表 "a\r\nb\rc") '("a" "b" "c"))
  ;; 逆：行列表->字符串 拼回
  (check-equal? (行列表->字符串 '("a" "b")) "a\nb")
  (check-equal? (行列表->字符串 (字符串->行列表 "a\r\nb")) "a\nb")

  ;; 行几何：与 字符串->行列表 的 length / last 一致（\n / \r\n / \r 都要归一）
  (for ([s (in-list '("" "a" "a\nb" "a\n" "\n" "a\r\nb\rc" "a\r" "\r\n" "中\n文"))])
    (check-equal? (字符串-行-数量 s) (length (字符串->行列表 s)))
    (check-equal? (字符串-末-行-长度 s) (string-length (last (字符串->行列表 s)))))
  (displayln "lines.rkt: all tests passed"))
