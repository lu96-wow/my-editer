#lang racket

;;; edit/plugin/builtin/bracket-pair.rkt —— 括号配对 + 嵌套深度（纯）
;;;
;;; 表示：匹配对 → 整段区间 (list ol oc cl cc level)，level = 嵌套层（最外层 = 0）。
;;; 外层先写、内层后写覆盖 → 每字符取最内层包围它的对。face = (palette-bg 'bracket level)。
;;;
;;; Racket 文件按词法**跳过**字符串 "…"、行注释 ;…、块注释 #| … |#（可嵌套）、
;;; 字符字面量 #\x 里的括号；其它文件按裸括号配对。用**哨兵栈项**（'string / 'block）
;;; 表示跳过态，随行边界保存，于是跨行字符串 / 注释也能被增量算法处理。
;;; ⚠ 未处理 #; datum 注释。
;;;
;;;   bracket-fills   朴素全量（参考 / 测试）
;;;   bracket-open    全量 → bstate
;;;   bracket-change  增量：找到被破坏的最浅深度 D，重建到栈重新对齐的行 E；
;;;                   返回 (values bstate pairs)，pairs 是**整篇**（kept ++ 重建段）。

(require racket/match
         racket/string
         "../../core/file-kind.rkt"
         "../../core/face.rkt"
         "../../../core/text/base/line.rkt")

(provide bracket-fills
         bracket-open bracket-open* bracket-change
         (struct-out bstate))

;; ---------- 记号 ----------

(define open->close (hash #\( #\) #\[ #\] #\{ #\}))
(define (open-ch? ch) (and (char? ch) (hash-has-key? open->close ch)))
(define (close-ch? ch) (and (char? ch) (memv ch '(#\) #\] #\}))))
(define (bracket-entry? e) (and (pair? e) (open-ch? (car e))))
(define (string-entry? e) (eq? (car e) 'string))
(define (block-entry? e) (eq? (car e) 'block))
(define (matches? e ch) (and (bracket-entry? e) (eqv? (hash-ref open->close (car e)) ch)))

(define (entry-pos e) (list (cadr e) (caddr e)))
(define (pos<? a b) (or (< (car a) (car b)) (and (= (car a) (car b)) (< (cadr a) (cadr b)))))
(define (pos<=? a b) (or (pos<? a b) (equal? a b)))

;; 栈里括号层数（字符串 / 注释哨兵不算）。
(define (stack-level stack)
  (for/sum ([e (in-list stack)] #:when (bracket-entry? e)) 1))

;;; ================= 逐段扫描（Racket 词法感知） =================

;; 扫 line 的 [start,end) 段；stack0 = 段前栈。syntax? = 是否按 Racket 跳过字符串 / 注释。
;; 返回 (values stack* fills)；fill = (list ol oc cl cc level)，**按时间顺序**（先闭合的在前）。
(define (scan-slice line ln start end stack0 syntax?)
  (define stack stack0)
  (define rev '())
  (define n (min end (string-length line)))
  (let loop ([i start])
    (cond
      [(>= i n) (values stack (reverse rev))]
      [else
       (define ch (string-ref line i))
       (define top (and (pair? stack) (car stack)))
       (cond
         [(and syntax? top (string-entry? top))
          (cond
            [(char=? ch #\\) (loop (min n (+ i 2)))]
            [(char=? ch #\") (set! stack (cdr stack)) (loop (add1 i))]
            [else (loop (add1 i))])]
         [(and syntax? top (block-entry? top))
          (cond
            [(and (< (add1 i) n) (char=? ch #\|) (char=? (string-ref line (add1 i)) #\#))
             (set! stack (cdr stack)) (loop (+ i 2))]
            [(and (< (add1 i) n) (char=? ch #\#) (char=? (string-ref line (add1 i)) #\|))
             (set! stack (cons (list 'block ln i) stack)) (loop (+ i 2))]
            [else (loop (add1 i))])]
         [(and syntax? (char=? ch #\;)) (values stack (reverse rev))]
         [(and syntax? (char=? ch #\#) (< (add1 i) n)
               (char=? (string-ref line (add1 i)) #\|))
          (set! stack (cons (list 'block ln i) stack)) (loop (+ i 2))]
         [(and syntax? (char=? ch #\#) (< (add1 i) n)
               (char=? (string-ref line (add1 i)) #\\))
          (loop (min n (+ i 3)))]
         [(and syntax? (char=? ch #\"))
          (set! stack (cons (list 'string ln i) stack)) (loop (add1 i))]
         [(open-ch? ch)
          (set! stack (cons (list ch ln i (stack-level stack)) stack))
          (loop (add1 i))]
         [(close-ch? ch)
          (when (matches? top ch)
            (define e top)
            (set! stack (cdr stack))
            (set! rev (cons (list (cadr e) (caddr e) ln (add1 i) (list-ref e 3)) rev)))
          (loop (add1 i))]
         [else (loop (add1 i))])])))

;;; ================= 朴素全量（参考） =================

(define (bracket-fills text [syntax? #f])
  (define stack '())
  (define fills '())
  (for ([line (in-list (string->lines text))] [ln (in-naturals)])
    (define-values (stack* fl) (scan-slice line ln 0 (string-length line) stack syntax?))
    (set! stack stack*)
    (for ([f (in-list fl)])
      (set! fills (cons (list (car f) (cadr f) (caddr f) (cadddr f)
                              (palette-bg 'bracket (list-ref f 4)))
                        fills))))
  fills)

;;; ================= 全量 → bstate =================

(struct bstate (lines entries pairs) #:transparent)
;; lines   : vector of string
;; entries : vector，每行行首的栈
;; pairs   : 匹配对区间 (list ol oc cl cc level)

(define (bracket-open text path)
  (bracket-open* (list->vector (string->lines text)) path))

(define (bracket-open* lines path)
  (define syntax? (racket-file? path))
  (define-values (entries pairs _)
    (scan-range lines 0 (vector-length lines) '() (list 0 0) syntax?))
  (values (bstate lines entries pairs) pairs))

;; 扫整行 [from,to)。start-pos 之前的开括号不产出 pair（保留旧对）。
(define (scan-range lines from to stack0 start-pos syntax?)
  (define n (- to from))
  (define entries (make-vector n))
  (define pairs '())
  (define stack stack0)
  (for ([i (in-range from to)] [k (in-naturals)])
    (vector-set! entries k stack)
    (define line (vector-ref lines i))
    (define-values (stack* fl) (scan-slice line i 0 (string-length line) stack syntax?))
    (set! stack stack*)
    (for ([f (in-list fl)]
          #:when (pos<=? start-pos (list (car f) (cadr f))))
      (set! pairs (cons (list (car f) (cadr f) (caddr f) (cadddr f) (list-ref f 4)) pairs))))
  (values entries pairs stack))

;;; ================= 增量 =================

;; → (values bstate pairs)。行结构变化或多编辑 → 整篇重扫。
(define (bracket-change st edits lines path)
  (define syntax? (racket-file? path))
  (define old-lines (bstate-lines st))
  (cond
    [(or (not (= 1 (length edits)))
         (let ([e (car edits)])
           (or (not (= (list-ref e 0) (list-ref e 2)))
               (not (= (vector-length old-lines) (vector-length lines))))))
     (bracket-open* lines path)]
    [else
     (match-define (list l0 c0 l1 c1) (car edits))
     (define old-entries (bstate-entries st))
     (define old-pairs (bstate-pairs st))
     (define a (list l0 c0))
     ;; D：被破坏的最浅深度 = 编辑处栈里最外层（最底）的开括号；栈空则 a
     (define S-edit (scan-prefix old-entries (vector-ref old-lines l0) l0 c0 syntax?))
     (define D (if (null? S-edit) a (entry-pos (last S-edit))))
     (define-values (E stack-E) (find-end lines old-entries D l0 syntax?))
     (define open-set (if (< E (vector-length lines))
                          (for/list ([e (in-list stack-E)]) (entry-pos e))
                          '()))
     (define-values (region-entries region-pairs _)
       (scan-range lines (car D) E (vector-ref old-entries (car D)) D syntax?))
     (define new-entries
       (list->vector
        (append (for/list ([i (in-range (car D))]) (vector-ref old-entries i))
                (vector->list region-entries)
                (for/list ([i (in-range E (vector-length lines))]) (vector-ref old-entries i)))))
     ;; 保留 open < D / open >= E / 在 E 处仍开着的旧对；其余由重建段替代。
     (define kept
       (for/list ([f (in-list old-pairs)]
                  #:when (let ([o (list (car f) (cadr f))])
                           (or (pos<? o D) (pos<=? (list E 0) o)
                               (for/or ([p (in-list open-set)]) (equal? p o)))))
         f))
     (values (bstate lines new-entries (append kept region-pairs))
             (append kept region-pairs))]))

;; 从 D 所在行首起扫（#| / |# / #\x 可能跨过 D），直到栈完全等于旧入口栈。
(define (find-end lines old-entries D l0 syntax?)
  (define n (vector-length lines))
  (define dl (car D))
  (define stack (vector-ref old-entries dl))
  (define E #f)
  (define (check! next)
    (when (and (not E) (> next l0))
      (if (= next n)
          (set! E n)
          (when (equal? stack (vector-ref old-entries next)) (set! E next)))))
  (define line0 (vector-ref lines dl))
  (define-values (stack* _) (scan-slice line0 dl 0 (string-length line0) stack syntax?))
  (set! stack stack*)
  (check! (add1 dl))
  (for ([i (in-range (add1 dl) n)] #:break (and E #t))
    (define line (vector-ref lines i))
    (define-values (stack* _) (scan-slice line i 0 (string-length line) stack syntax?))
    (set! stack stack*)
    (check! (add1 i)))
  (values (or E n) stack))

;; 行 line 的 [0,col) 处取栈。
(define (scan-prefix entries line-text line col syntax?)
  (define stack (vector-ref entries line))
  (define-values (stack* _) (scan-slice line-text line 0 col stack syntax?))
  stack*)
