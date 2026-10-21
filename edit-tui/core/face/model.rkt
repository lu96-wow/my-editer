#lang racket

;;; edit-tui-rebuild/face/model.rkt —— face 值 + 分层合成（纯）
;;;
;;; face 三分量：
;;;   fg    : #f | symbol
;;;   bg    : #f | symbol
;;;   attrs : (listof symbol)
;;;
;;; 裸 symbol 表示“整格换风格”；face 表示逐分量叠加。
;;; 这里不解释颜色 / 属性，后端只认符号。

(require racket/list
         racket/match)

(provide (struct-out face)
         face-empty
         face-set-fg face-set-bg face-set-attrs
         face-add-attr face-remove-attr face-has-attr?
         compose-face
         compose-layers)

(struct face (fg bg attrs) #:prefab)
;; fg/bg : #f | symbol
;; attrs : (listof symbol)

(define face-empty (face #f #f '()))

;;; ════════════════ 写 ════════════════

(define (face-set-fg f v)
  (if f (struct-copy face f [fg v]) (face v #f '())))

(define (face-set-bg f v)
  (if f (struct-copy face f [bg v]) (face #f v '())))

(define (face-set-attrs f v)
  (if f (struct-copy face f [attrs v]) (face #f #f v)))

(define (face-add-attr f a)
  (define f* (or f face-empty))
  (if (memq a (face-attrs f*))
      f*
      (face-set-attrs f* (append (face-attrs f*) (list a)))))

(define (face-remove-attr f a)
  (and f (face-set-attrs f (remq a (face-attrs f)))))

(define (face-has-attr? f a)
  (and f (and (memq a (face-attrs f)) #t)))

;;; ════════════════ 合成 ════════════════

;; new 的非 #f 分量覆盖 old；attrs 取并集。
;; 任一侧是裸 symbol → 整体覆盖。
(define (compose-face old new)
  (cond
    [(not new) old]
    [(not old) new]
    [(or (symbol? old) (symbol? new)) new]
    [else
     (face (or (face-fg new) (face-fg old))
           (or (face-bg new) (face-bg old))
           (remove-duplicates (append (face-attrs old) (face-attrs new))))]))

;;; ════════════════ 多层 fills 合成 ════════════════

;; order  : (listof symbol)
;; layers : (hash/c symbol (listof fill))
;; fill   : (list l0 c0 l1 c1 face)   ; 行/列半开
;;
;; line-length : line -> nat | #f。跨行 fill 的中间行需要知道行宽；
;;               #f 时退回用 c1 作为上界（有限，不会再出现 +inf.0 死循环）。
;;
;; 返回合成后的 fills（按行、列升序，相邻同 face 合并）。
(define (compose-layers order layers
                        #:line-length [line-length #f])
  (define effective-order
    (append order
            (sort (for/list ([k (in-hash-keys layers)] #:unless (memq k order)) k)
                  symbol<?)))
  (define cells (make-hash))
  (for ([layer (in-list effective-order)])
    (for ([f (in-list (hash-ref layers layer '()))])
      (match-define (list l0 c0 l1 c1 v) f)
      (for ([l (in-range l0 (add1 l1))])
        (define a (if (= l l0) c0 0))
        (define b
          (cond
            [(= l l1) c1]
            [line-length (line-length l)]
            [else c1]))
        (for ([c (in-range a b)])
          (define k (cons l c))
          (hash-set! cells k (compose-face (hash-ref cells k #f) v))))))
  (define ks (sort (hash-keys cells)
                   (λ (a b) (or (< (car a) (car b))
                                (and (= (car a) (car b)) (< (cdr a) (cdr b)))))))
  (reverse
   (for/fold ([acc '()]) ([k (in-list ks)])
     (define l (car k))
     (define c (cdr k))
     (define v (hash-ref cells k))
     (cond
       [(and (pair? acc)
             (= (list-ref (car acc) 0) l)
             (= (list-ref (car acc) 3) c)
             (equal? (list-ref (car acc) 4) v))
        (cons (list (list-ref (car acc) 0) (list-ref (car acc) 1)
                    l (add1 c) v)
              (cdr acc))]
       [else (cons (list l c l (add1 c) v) acc)]))))
