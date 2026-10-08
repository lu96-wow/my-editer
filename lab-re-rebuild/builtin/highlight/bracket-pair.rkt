#lang racket

(require racket/string
         "../../kernel/api.rkt"
         "../lang/file-kind.rkt")

;;; lab-re-rebuild/builtin/highlight/bracket-pair.rkt —— 括号配对 + 嵌套深度
;;;
;;; 表示：匹配对 → 整段区间 (list ol oc cl cc (palette-color 'bracket level))，level = 嵌套层
;;; （最外层 = 0）。外层先写、内层后写覆盖 → 每字符取最内层包围它的对。
;;;
;;; Racket 文件（扩展名见 file-kind.rkt）按词法**跳过**字符串 "…"、行注释 ;…、
;;; 块注释 #| … |#（可嵌套）、字符字面量 #\x 里的括号；其它文件仍按裸括号配对。
;;; 跳过用**哨兵栈项**表示（'string / 'block 压在括号栈顶，随行边界保存），
;;; 于是跨行字符串 / 注释也能被增量算法原样处理（栈相等即状态相等）。
;;; ⚠ 未处理 #; datum 注释（要读完整 datum）；#; 后跟的括号会被当成普通括号。
;;;
;;;   bracket-fills   朴素全量（参考 / 测试）
;;;   bracket-open    全量 → bstate（文本 + 每行入口栈 + fills）
;;;   bracket-change  增量
;;;
;;; 增量（“找到破坏平衡的最小深度并重建”）：
;;;   编辑前区间 [a,b) 在行 l0，编辑点处的栈 S_edit。
;;;   D = S_edit 里**最外层（最底）**那个开括号的位置（栈空则 a）—— 被破坏的最浅深度。
;;;   从 D 所在**行首**重建（词法多字符记号可能跨过 D），直到第一个（在 l0 之后的）行边界 E，
;;;   使栈**完全等于旧入口栈**。
;;;   于是 [D,E) 内开的所有对都重新算，且 E 之后的嵌套/层号/fills 不变。
;;;   fills 保留：open < D、open >= E、以及“在 E 处仍开着（位置与旧一致）”的旧对；
;;;   其余（[D,E) 内已闭合的）由重建段替代。
;;;
;;; 行结构变化（跨行 / 插入含换行）会破坏“行列对齐”，直接整篇重算；行内编辑走增量。
;;; 等价性：lab/smoke-bracket.rkt（随机对比 增量 vs 全量）。

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
;; 字符串 / 注释用哨兵项压在栈顶，跨行时随 entries 保留。
(define (scan-slice line ln start end stack0 syntax?)
  (define stack stack0)
  (define rev '())                                ; 逆序累积 → 返回时 reverse
  (define n (min end (string-length line)))
  (let loop ([i start])
    (cond
      [(>= i n) (values stack (reverse rev))]
      [else
       (define ch (string-ref line i))
       (define top (and (pair? stack) (car stack)))
       (cond
         ;; 字符串内：\ 转义下一字符（行尾 = 转义换行，字符串继续），其余找结束 "
         [(and syntax? top (string-entry? top))
          (cond
            [(char=? ch #\\) (loop (min n (+ i 2)))]
            [(char=? ch #\") (set! stack (cdr stack)) (loop (add1 i))]
            [else (loop (add1 i))])]
         ;; 块注释内：#| 嵌套 +1，|# 结束
         [(and syntax? top (block-entry? top))
          (cond
            [(and (< (add1 i) n) (char=? ch #\|) (char=? (string-ref line (add1 i)) #\#))
             (set! stack (cdr stack)) (loop (+ i 2))]
            [(and (< (add1 i) n) (char=? ch #\#) (char=? (string-ref line (add1 i)) #\|))
             (set! stack (cons (list 'block ln i) stack)) (loop (+ i 2))]
            [else (loop (add1 i))])]
         ;; 正常：行注释 ; 到行尾
         [(and syntax? (char=? ch #\;)) (values stack (reverse rev))]
         ;; 正常：#| 块注释开始
         [(and syntax? (char=? ch #\#) (< (add1 i) n)
               (char=? (string-ref line (add1 i)) #\|))
          (set! stack (cons (list 'block ln i) stack)) (loop (+ i 2))]
         ;; 正常：#\<char> 字符字面量（#\( #\) #\; 等；具名字符多跳一个也无碍）
         [(and syntax? (char=? ch #\#) (< (add1 i) n)
               (char=? (string-ref line (add1 i)) #\\))
          (loop (min n (+ i 3)))]
         ;; 正常：" 字符串开始
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
                              (palette-color 'bracket (list-ref f 4)))
                        fills))))
  fills)

;;; ================= 全量 → bstate =================

(struct bstate (lines entries fills) #:transparent)
;; lines   : vector of string
;; entries : vector，每行行首的栈（entry = (list ch line col level) / ('string line col)
;;           / ('block line col)，top 前，共享结构）
;; fills   : 匹配对区间

(define (bracket-open text path)
  (bracket-open* (list->vector (string->lines text)) path))

(define (bracket-open* lines path)
  (define syntax? (racket-file? path))
  (define-values (entries fills _)
    (scan-range lines 0 (vector-length lines) '() (list 0 0) syntax?))
  (values (bstate lines entries fills) fills))

;; 扫整行 [from,to)，from 行首起。start-pos 之前的开括号不产出 fill（保留旧对）。
(define (scan-range lines from to stack0 start-pos syntax?)
  (define n (- to from))
  (define entries (make-vector n))
  (define fills '())
  (define stack stack0)
  (for ([i (in-range from to)] [k (in-naturals)])
    (vector-set! entries k stack)
    (define line (vector-ref lines i))
    (define-values (stack* fl) (scan-slice line i 0 (string-length line) stack syntax?))
    (set! stack stack*)
    (for ([f (in-list fl)]
          #:when (pos<=? start-pos (list (car f) (cadr f))))
      (set! fills (cons (list (car f) (cadr f) (caddr f) (cadddr f)
                              (palette-color 'bracket (list-ref f 4)))
                        fills))))
  (values entries fills stack))

;;; ================= 增量 =================

(define (bracket-change st edit lines path)
  (define syntax? (racket-file? path))
  (match-define (list l0 c0 l1 c1 inserted) edit)
  (cond
    [(or (not (= l0 l1)) (regexp-match? #rx"\n" inserted))
     (bracket-open* lines path)]
    [else
     (define old-lines (bstate-lines st))
     (define old-entries (bstate-entries st))
     (define old-fills (bstate-fills st))
     (define new-lines lines)
     (define a (list l0 c0))
     ;; D：“被破坏的最浅深度” = 编辑处栈里最外层（最底）的那个开括号；栈空则 a
     (define S-edit (scan-prefix old-entries (vector-ref old-lines l0) l0 c0 syntax?))
     (define D (if (null? S-edit) a (entry-pos (last S-edit))))
     (define-values (E stack-E) (find-end new-lines old-entries D l0 syntax?))
     (define open-set (if (< E (vector-length new-lines))
                           (for/list ([e (in-list stack-E)]) (entry-pos e))
                           '()))
     (define-values (region-entries region-fills _)
       (scan-range new-lines (car D) E (vector-ref old-entries (car D)) D syntax?))
     (define new-entries
       (list->vector
        (append (for/list ([i (in-range (car D))]) (vector-ref old-entries i))
                (vector->list region-entries)
                (for/list ([i (in-range E (vector-length new-lines))]) (vector-ref old-entries i)))))
     ;; 保留 open < D / open >= E / 在 E 处仍开着的（位置与旧一致、对没变）的旧对；
     ;; 完全落在 [D,E) 内且已在重建段里闭合的旧对，由重建段替代。
     (define kept
       (for/list ([f (in-list old-fills)]
                  #:when (let ([o (list (car f) (cadr f))])
                           (or (pos<? o D) (pos<=? (list E 0) o)
                               (for/or ([p (in-list open-set)]) (equal? p o)))))
         f))
     (define new-fills (append kept region-fills))
     (values (bstate new-lines new-entries new-fills) new-fills)]))

;; 从 D 所在**行首**起扫（不能从 D 列起：`#|`/`|#`/`#\x` 可能跨过 D），
;; 直到栈完全等于旧入口栈（只查编辑行之后的边界）；
;; 返回 (values E stack-E)：E = 区间的开区间上界；stack-E = E 处的栈。
(define (find-end new-lines old-entries D l0 syntax?)
  (define n (vector-length new-lines))
  (define dl (car D))
  (define stack (vector-ref old-entries dl))
  (define E #f)
  (define (check! next)
    (when (and (not E) (> next l0))
      (if (= next n)
          (set! E n)
          (when (equal? stack (vector-ref old-entries next)) (set! E next)))))
  (define line0 (vector-ref new-lines dl))
  (define-values (stack* _) (scan-slice line0 dl 0 (string-length line0) stack syntax?))
  (set! stack stack*)
  (check! (add1 dl))
  (for ([i (in-range (add1 dl) n)] #:break (and E #t))
    (define line (vector-ref new-lines i))
    (define-values (stack* _) (scan-slice line i 0 (string-length line) stack syntax?))
    (set! stack stack*)
    (check! (add1 i)))
  (values (or E n) stack))

;; 行 line 的 [0,col) 处取栈
(define (scan-prefix entries line-text line col syntax?)
  (define stack (vector-ref entries line))
  (define-values (stack* _) (scan-slice line-text line 0 col stack syntax?))
  stack*)
