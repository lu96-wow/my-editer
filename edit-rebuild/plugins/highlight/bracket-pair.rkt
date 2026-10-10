#lang racket

;;; edit-rebuild/plugins/highlight/bracket-pair.rkt —— 括号配对 + 嵌套深度（纯，按行增量）
;;;
;;; 表示：每行行首的**括号栈**（entries）+ 由栈派生的每行背景向量。
;;;   背景 = 最内层包围该字符的括号对的 level（最外层 = 0）；不在任何对里 = #f。
;;;
;;; 行局部：给定行首栈，单行向量可独立算出（bracket-line）。
;;; 跨行状态（栈）只在编辑处附近重建（bracket-change）：
;;;   找到被破坏的最浅深度 D，重建到栈与旧行首栈重新对齐的 E，[D,E) 即脏行。
;;;
;;; Racket 文件按词法**跳过**字符串 "…"、行注释 ;…、块注释 #| … |#（可嵌套）、
;;; 字符字面量 #\x 里的括号；哨兵（'string / 'block）压栈并随行首栈保留，
;;; 于是跨行字符串 / 注释也能被增量算法原样处理（栈相等即状态相等）。
;;; ⚠ 未处理 #; datum 注释。
;;;
;;;   bracket-open*    全量 → (values bstate layer)
;;;   bracket-layer    由 entries 重建整条 layer
;;;   bracket-change   增量：只重建 [D,E) 行，返回 (values bstate dirty)

(require "../../core/face/kind.rkt"
         "../../core/face/face.rkt"
         "../../core/face/line-scan.rkt"
         "../../../core/text/base/change.rkt"
         "../../../core/text/base/point.rkt"
         "../../../core/text/base/range.rkt"
         "../../../core/text/base/track.rkt")

(provide bracket-open* bracket-change bracket-layer bracket-line
         (struct-out bstate))

;;; ---------- 记号 ----------

(define open->close (hash #\( #\) #\[ #\] #\{ #\}))
(define (open-ch? ch) (and (char? ch) (hash-has-key? open->close ch)))
(define (close-ch? ch) (and (char? ch) (memv ch '(#\) #\] #\}))))
(define (bracket-entry? e) (and (pair? e) (open-ch? (car e))))
(define (string-entry? e) (eq? (car e) 'string))
(define (block-entry? e) (eq? (car e) 'block))
(define (matches? e ch) (and (bracket-entry? e) (eqv? (hash-ref open->close (car e)) ch)))
(define (entry-pos e) (list (cadr e) (caddr e)))

;; 栈里括号层数（字符串 / 注释哨兵不算）。
(define (stack-level stack)
  (for/sum ([e (in-list stack)] #:when (bracket-entry? e)) 1))

;;; ---------- 行 → 背景向量 ----------

;; 扫一整行；返回 (values (vectorof face)|#f 行尾栈)。
;; 每格的背景 = 最内层包围它的括号对 level；不在任何对里 → #f。
(define (bracket-line line ln stack syntax?)
  (define n (string-length line))
  (define vec (make-vector n #f))
  (define touched? #f)
  (define st stack)
  (define (emit! i lvl)
    (when (>= lvl 0)
      (set! touched? #t)
      (vector-set! vec i (palette-bg 'bracket lvl))))
  (define (emit-code! i) (emit! i (sub1 (stack-level st))))
  (let loop ([i 0])
    (cond
      [(>= i n) (values (and touched? vec) st)]
      [else
       (define ch (string-ref line i))
       (define top (and (pair? st) (car st)))
       (cond
         ;; 字符串内：\ 转义下一字符；" 结束；其余跳过（不上括号色）
         [(and syntax? top (string-entry? top))
          (cond
            [(char=? ch #\\)
             (emit-code! i)
             (when (< (add1 i) n) (emit-code! (add1 i)))
             (loop (min n (+ i 2)))]
            [(char=? ch #\") (emit-code! i) (set! st (cdr st)) (loop (add1 i))]
            [else (emit-code! i) (loop (add1 i))])]
         ;; 块注释内：#| 嵌套 +1，|# 结束
         [(and syntax? top (block-entry? top))
          (cond
            [(and (< (add1 i) n) (char=? ch #\|) (char=? (string-ref line (add1 i)) #\#))
             (emit-code! i) (emit-code! (add1 i)) (set! st (cdr st)) (loop (+ i 2))]
            [(and (< (add1 i) n) (char=? ch #\#) (char=? (string-ref line (add1 i)) #\|))
             (emit-code! i) (emit-code! (add1 i))
             (set! st (cons (list 'block ln i) st)) (loop (+ i 2))]
            [else (emit-code! i) (loop (add1 i))])]
         ;; 行注释：本行剩下都是注释，画完即停
         [(and syntax? (char=? ch #\;))
          (for ([j (in-range i n)]) (emit-code! j))
          (values (and touched? vec) st)]
         ;; #| 块注释开始
         [(and syntax? (char=? ch #\#) (< (add1 i) n) (char=? (string-ref line (add1 i)) #\|))
          (emit-code! i) (emit-code! (add1 i))
          (set! st (cons (list 'block ln i) st)) (loop (+ i 2))]
         ;; #\<char> 字符字面量（#\( #\) #\; 等；具名字符多跳一个也无碍）
         [(and syntax? (char=? ch #\#) (< (add1 i) n) (char=? (string-ref line (add1 i)) #\\))
          (emit-code! i) (emit-code! (add1 i))
          (when (< (+ i 2) n) (emit-code! (+ i 2)))
          (loop (min n (+ i 3)))]
         ;; " 字符串开始
         [(and syntax? (char=? ch #\"))
          (emit-code! i) (set! st (cons (list 'string ln i) st)) (loop (add1 i))]
         ;; 开括号：它属于自己那对，level = 入栈前括号层数
         [(open-ch? ch)
          (emit! i (stack-level st))
          (set! st (cons (list ch ln i (stack-level st)) st))
          (loop (add1 i))]
         ;; 闭括号：先配对出栈，level = 出栈后括号层数（= 该对 level）
         [(close-ch? ch)
          (when (matches? top ch) (set! st (cdr st)))
          (emit! i (stack-level st))
          (loop (add1 i))]
         [else (emit-code! i) (loop (add1 i))])])))

;;; ---------- 全量 ----------

(struct bstate (nlines entries) #:transparent)
;; nlines  : nat
;; entries : (vectorof stack)   每行行首的栈（top 前，共享结构）

;; 全量：建 entries + 层。返回 (values bstate layer)。
(define (bracket-open* text path)
  (define syntax? (racket-file? path))
  (define n (track-length text))
  (define entries (make-vector n '()))
  (define layers (make-vector n #f))
  (define st '())
  (for ([i (in-range n)])
    (vector-set! entries i st)
    (define-values (vec st*) (bracket-line (track-ref text i) i st syntax?))
    (vector-set! layers i vec)
    (set! st st*))
  (values (bstate n entries)
          (track-of-list (vector->list layers))))

;; 由 entries 重建整条层。
(define (bracket-layer text entries path)
  (define syntax? (racket-file? path))
  (track-of-list
   (for/list ([i (in-range (track-length text))])
     (define-values (vec _) (bracket-line (track-ref text i) i (vector-ref entries i) syntax?))
     vec)))

;;; ---------- 增量 ----------

(define (cross-line-change? ch)
  (define b (change-before ch))
  (define a (change-after ch))
  (or (not (= (point-line (range-start b)) (point-line (range-end b))))
      (not (= (point-line (range-start a)) (point-line (range-end a))))))

;; → (values bstate dirty)。
;; 行结构变化 / 多编辑 → 整篇；单行内编辑 → 只重建 [D,E)。
(define (bracket-change st changes text path)
  (define syntax? (racket-file? path))
  (define n (track-length text))
  (define old-n (bstate-nlines st))
  (define old-entries (bstate-entries st))
  (cond
    [(or (not (= 1 (length changes)))
         (cross-line-change? (car changes))
         (not (= old-n n)))
     (define-values (st* _layer) (bracket-open* text path))
     (values st* (dirty-all))]
    [else
     (define r (change-post-range (car changes)))
     (define l0 (point-line (range-start r)))
     (define c0 (point-column (range-start r)))
     ;; D：被破坏的最浅深度 = 编辑处栈里最外层（最底）的开括号；栈空则 a
     (define S-edit (scan-prefix old-entries (track-ref text l0) l0 c0 syntax?))
     (define D (if (null? S-edit) (list l0 c0) (entry-pos (last S-edit))))
     (define-values (E _stack-E) (find-end text old-entries D l0 syntax?))
     (define-values (region-entries _)
       (scan-entries text (car D) E (vector-ref old-entries (car D)) syntax?))
     (define new-entries
       (list->vector
        (append (for/list ([i (in-range (car D))]) (vector-ref old-entries i))
                (vector->list region-entries)
                (for/list ([i (in-range E n)]) (vector-ref old-entries i)))))
     (values (bstate n new-entries)
             (dirty-lines (for/list ([i (in-range (car D) E)]) i)))]))

;; 从 from 行扫到 to 行，记录每行行首栈；返回 (values entries 行尾栈)。
(define (scan-entries text from to stack0 syntax?)
  (define entries (make-vector (- to from)))
  (define st stack0)
  (for ([i (in-range from to)] [k (in-naturals)])
    (vector-set! entries k st)
    (define-values (_ st*) (bracket-line (track-ref text i) i st syntax?))
    (set! st st*))
  (values entries st))

;; 从 D 所在行首起扫（#| / |# / #\x 可能跨过 D），直到栈与旧行首栈重新对齐
;; （只查编辑行之后的边界）；返回 (values E stack-E)。
(define (find-end text old-entries D l0 syntax?)
  (define n (track-length text))
  (define dl (car D))
  (define stack (vector-ref old-entries dl))
  (define E #f)
  (define (check! next)
    (when (and (not E) (> next l0))
      (if (= next n)
          (set! E n)
          (when (equal? stack (vector-ref old-entries next)) (set! E next)))))
  (define-values (_ st*) (bracket-line (track-ref text dl) dl stack syntax?))
  (set! stack st*)
  (check! (add1 dl))
  (for ([i (in-range (add1 dl) n)] #:break (and E #t))
    (define-values (_ st2) (bracket-line (track-ref text i) i stack syntax?))
    (set! stack st2)
    (check! (add1 i)))
  (values (or E n) stack))

;; 行 line-text 的 [0,col) 处取栈。
(define (scan-prefix entries line-text line col syntax?)
  (define stack (vector-ref entries line))
  (define-values (_ st*) (bracket-line (substring line-text 0 col) line stack syntax?))
  st*)
