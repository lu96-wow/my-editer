#lang racket

;;; plugins/highlight/depth.rkt —— 括号深度扫描（纯）：逐行背景
;;;
;;; layer  : plugins/highlight
;;; effect : 无（纯：文本 / 行 -> 背景向量）
;;;
;;; 每格背景 = 最内层包围它的括号对的深度；不在任何括号里 = #f。
;;; 会跳过字符串、行注释、块注释（可嵌套）、字符字面量里的括号；
;;; 跨行状态是一份括号 / 字符串 / 块的栈，交给 decor 的 stateful-advance 增量推进。
;;;
;;; 这是 face-decor 的行级接口；depth-fills 保留给旧的整篇扫描 / worker。

(provide depth-fills
         depth-line
         depth-face-of)

(define max-depth 8)

;; 深度 -> 背景 face 名（超出上限按上限）
(define (depth-face-of depth)
  (define d (max 1 (min depth max-depth)))
  (case d
    [(1) 'bg-depth-1]
    [(2) 'bg-depth-2]
    [(3) 'bg-depth-3]
    [(4) 'bg-depth-4]
    [(5) 'bg-depth-5]
    [(6) 'bg-depth-6]
    [(7) 'bg-depth-7]
    [else 'bg-depth-8]))

;;; ════════════════ 括号栈 ════════════════

(define open->close (hash #\( #\) #\[ #\] #\{ #\}))
(define (open-ch? ch) (and (char? ch) (hash-has-key? open->close ch)))
(define (close-ch? ch) (and (char? ch) (memv ch '(#\) #\] #\}))))
(define (bracket-entry? e) (and (pair? e) (open-ch? (car e))))
(define (string-entry? e) (eq? (car e) 'string))
(define (block-entry? e) (eq? (car e) 'block))
(define (matches? e ch) (and (bracket-entry? e) (eqv? (hash-ref open->close (car e)) ch)))

;; 栈里括号层数（字符串 / 注释哨兵不算）。
(define (stack-level stack)
  (for/sum ([e (in-list stack)] #:when (bracket-entry? e)) 1))

;; 扫一整行；返回 (values 行尾栈 face 向量)。
(define (depth-line stack line)
  (define n (string-length line))
  (define vec (make-vector n #f))
  (define st stack)
  (define (emit! i lvl)
    (when (and (>= lvl 0) (< i n))
      (vector-set! vec i (depth-face-of (add1 lvl)))))
  (define (emit-code! i) (emit! i (sub1 (stack-level st))))
  (let loop ([i 0])
    (cond
      [(>= i n) (values st vec)]
      [else
       (define ch (string-ref line i))
       (define top (and (pair? st) (car st)))
       (cond
         ;; 字符串内部
         [(and top (string-entry? top))
          (cond
            [(char=? ch #\\)
             (emit-code! i)
             (when (< (add1 i) n) (emit-code! (add1 i)))
             (loop (min n (+ i 2)))]
            [(char=? ch #\") (emit-code! i) (set! st (cdr st)) (loop (add1 i))]
            [else (emit-code! i) (loop (add1 i))])]
         ;; 块注释内部（可嵌套）
         [(and top (block-entry? top))
          (cond
            [(and (< (add1 i) n) (char=? ch #\|) (char=? (string-ref line (add1 i)) #\#))
             (emit-code! i) (emit-code! (add1 i)) (set! st (cdr st)) (loop (+ i 2))]
            [(and (< (add1 i) n) (char=? ch #\#) (char=? (string-ref line (add1 i)) #\|))
             (emit-code! i) (emit-code! (add1 i))
             (set! st (cons (list 'block) st)) (loop (+ i 2))]
            [else (emit-code! i) (loop (add1 i))])]
         ;; 行注释：行尾全部按当前深度
         [(char=? ch #\;)
          (for ([j (in-range i n)]) (emit-code! j))
          (values st vec)]
         ;; #| 开块注释
         [(and (char=? ch #\#) (< (add1 i) n) (char=? (string-ref line (add1 i)) #\|))
          (emit-code! i) (emit-code! (add1 i))
          (set! st (cons (list 'block) st)) (loop (+ i 2))]
         ;; #\x 字符字面量
         [(and (char=? ch #\#) (< (add1 i) n) (char=? (string-ref line (add1 i)) #\\))
          (emit-code! i) (emit-code! (add1 i))
          (when (< (+ i 2) n) (emit-code! (+ i 2)))
          (loop (min n (+ i 3)))]
         ;; " 字符串开始
         [(char=? ch #\")
          (emit-code! i) (set! st (cons (list 'string) st)) (loop (add1 i))]
         ;; 开括号：括号本身用“进入前”的深度
         [(open-ch? ch)
          (emit! i (stack-level st))
          (set! st (cons (list ch) st))
          (loop (add1 i))]
         ;; 闭括号：先弹栈，再用弹后深度
         [(close-ch? ch)
          (when (matches? top ch) (set! st (cdr st)))
          (emit! i (stack-level st))
          (loop (add1 i))]
         [else (emit-code! i) (loop (add1 i))])])))

;;; ════════════════ 整篇（旧接口 / worker） ════════════════

(define (vector->fills lno vec)
  (define n (vector-length vec))
  (let loop ([i 0] [acc '()])
    (cond
      [(>= i n) (reverse acc)]
      [else
       (define f (vector-ref vec i))
       (define j (let next ([j (add1 i)])
                   (if (and (< j n) (equal? (vector-ref vec j) f)) (next (add1 j)) j)))
       (loop j (if f (cons (list lno i lno j f) acc) acc))])))

;; 文本 -> fills（(list l0 c0 l1 c1 face)）；同一行内连续同深度合成一段。
(define (depth-fills text)
  (for/fold ([acc '()] [stack '()] #:result acc)
            ([line (in-list (string-split text "\n"))] [lno (in-naturals)])
    (define-values (stack* vec) (depth-line stack line))
    (values (append acc (vector->fills lno vec)) stack*)))
