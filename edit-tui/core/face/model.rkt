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

(require racket/list)

(provide (struct-out face)
         face-empty
         face-set-fg face-set-bg face-set-attrs
         face-add-attr face-remove-attr face-has-attr?
         compose-face)

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

