#lang racket

(require racket/string
         "../../core/text/base/line.rkt"
         "face.rkt")

;;; lab/base/brackets.rkt —— 括号配对 + 嵌套深度
;;;
;;; 表示：匹配对 → 整段区间 (list ol oc cl cc (palette-color 'bracket level))，level = 嵌套层
;;; （最外层 = 0）。外层先写、内层后写覆盖 → 每字符取最内层包围它的对。
;;;
;;;   bracket-fills   朴素全量（参考 / 测试）
;;;   bracket-open    全量 → bstate（文本 + 每行入口栈 + fills）
;;;   bracket-change  增量
;;;
;;; 增量（“找到破坏平衡的最小深度并重建”）：
;;;   编辑前区间 [a,b) 在行 l0，编辑点处的栈 S_edit。
;;;   D = S_edit 里**最外层（最底）**那个开括号的位置（栈空则 a）—— 被破坏的最浅深度。
;;;   从 D 起重建，直到第一个（在 l0 之后的）行边界 E，使栈**完全等于旧入口栈**。
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
(define (open-ch? ch) (hash-has-key? open->close ch))
(define (close-ch? ch) (memv ch '(#\) #\] #\})))
(define (matches? e ch) (eqv? (hash-ref open->close (car e)) ch))

(define (entry-pos e) (list (cadr e) (caddr e)))
(define (pos<? a b) (or (< (car a) (car b)) (and (= (car a) (car b)) (< (cadr a) (cadr b)))))
(define (pos<=? a b) (or (pos<? a b) (equal? a b)))

;;; ================= 朴素全量（参考） =================

(define (bracket-fills text)
  (define lines (string->lines text))
  (define stack '())
  (define fills '())
  (for ([line (in-list lines)] [ln (in-naturals)])
    (for ([ch (in-string line)] [col (in-naturals)])
      (cond
        [(open-ch? ch) (set! stack (cons (list ch ln col (length stack)) stack))]
        [(close-ch? ch)
         (when (and (pair? stack) (matches? (car stack) ch))
           (define e (car stack))
           (set! stack (cdr stack))
           (set! fills (cons (list (cadr e) (caddr e) ln (add1 col)
                                   (palette-color 'bracket (list-ref e 3)))
                             fills)))])))
  fills)

;;; ================= 全量 → bstate =================

(struct bstate (lines entries fills) #:transparent)
;; lines   : vector of string
;; entries : vector，每行行首的栈（entry = (list ch line col level)，top 前，共享结构）
;; fills   : 匹配对区间

(define (bracket-open text _path)
  (bracket-open* (list->vector (string->lines text)) _path))

(define (bracket-open* lines _path)
  (define-values (entries fills _) (scan-range lines 0 (vector-length lines) '() (list 0 0)))
  (values (bstate lines entries fills) fills))

;; 扫整行 [from,to)，from 行首起。start-pos 之前的开括号不产出 fill（保留旧对）。
(define (scan-range lines from to stack0 start-pos)
  (define n (- to from))
  (define entries (make-vector n))
  (define fills '())
  (define stack stack0)
  (for ([i (in-range from to)] [k (in-naturals)])
    (vector-set! entries k stack)
    (define line (vector-ref lines i))
    (for ([ch (in-string line)] [col (in-naturals)])
      (cond
        [(open-ch? ch) (set! stack (cons (list ch i col (length stack)) stack))]
        [(close-ch? ch)
         (when (and (pair? stack) (matches? (car stack) ch))
           (define e (car stack))
           (set! stack (cdr stack))
           (when (pos<=? start-pos (entry-pos e))
             (set! fills (cons (list (cadr e) (caddr e) i (add1 col)
                                     (palette-color 'bracket (list-ref e 3)))
                               fills))))])))
  (values entries fills stack))

;;; ================= 增量 =================

(define (bracket-change st edit lines _path)
  (match-define (list l0 c0 l1 c1 inserted) edit)
  (cond
    [(or (not (= l0 l1)) (regexp-match? #rx"\n" inserted))
     (bracket-open* lines _path)]
    [else
     (define old-lines (bstate-lines st))
     (define old-entries (bstate-entries st))
     (define old-fills (bstate-fills st))
     (define new-lines lines)
     (define a (list l0 c0)) (define b (list l0 c1))
     ;; D：“被破坏的最浅深度” = 编辑处栈里最外层（最底）的那个开括号；栈空则 a
     (define S-edit (scan-prefix old-entries (vector-ref old-lines l0) l0 c0))
     (define D (if (null? S-edit) a (entry-pos (last S-edit))))
     (define S-D (scan-prefix old-entries (vector-ref old-lines (car D)) (car D) (cadr D)))
     (define-values (E stack-E) (find-end new-lines old-entries D l0 S-D))
     (define open-set (if (< E (vector-length new-lines))
                           (for/list ([e (in-list stack-E)]) (entry-pos e))
                           '()))
     (define-values (region-entries region-fills _)
       (scan-range new-lines (car D) E (vector-ref old-entries (car D)) D))
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

;; 从 D（(line,col)）起扫，直到栈完全等于旧入口栈（只查编辑行之后的边界）；
;; 返回 (values E stack-E)：E = 区间的开区间上界；stack-E = E 处的栈。
(define (find-end new-lines old-entries D l0 S-D)
  (define n (vector-length new-lines))
  (define dl (car D)) (define dc (cadr D))
  (define stack S-D)
  (define E #f)
  (define line0 (vector-ref new-lines dl))
  (for ([ch (in-string line0)] [c (in-naturals)] #:when (>= c dc))
    (cond
      [(open-ch? ch) (set! stack (cons (list ch dl c (length stack)) stack))]
      [(close-ch? ch)
       (when (and (pair? stack) (matches? (car stack) ch)) (set! stack (cdr stack)))]))
  (define (check! next)
    (when (and (not E) (> next l0))
      (if (= next n)
          (set! E n)
          (when (equal? stack (vector-ref old-entries next)) (set! E next)))))
  (check! (add1 dl))
  (for ([i (in-range (add1 dl) n)] #:break (and E #t))
    (define line (vector-ref new-lines i))
    (for ([ch (in-string line)] [c (in-naturals)])
      (cond
        [(open-ch? ch) (set! stack (cons (list ch i c (length stack)) stack))]
        [(close-ch? ch)
         (when (and (pair? stack) (matches? (car stack) ch)) (set! stack (cdr stack)))]))
    (check! (add1 i)))
  (values (or E n) stack))

;; 行 line 的 [0,col) 处取栈
(define (scan-prefix entries line-text line col)
  (define stack (vector-ref entries line))
  (for ([ch (in-string line-text)] [c (in-naturals)] #:break (>= c col))
    (cond
      [(open-ch? ch) (set! stack (cons (list ch line c (length stack)) stack))]
      [(close-ch? ch)
       (when (and (pair? stack) (matches? (car stack) ch)) (set! stack (cdr stack)))]))
  stack)
