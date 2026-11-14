#lang racket

;;; derived projection：文本 + 逐字符 face 的按行增量安装。
;;;
;;; 覆盖：
;;;   · 首次 full；
;;;   · 同行数改行 / 插入 / 删除 / 末尾追加 / 删除尾部；
;;;   · face-only 变化；
;;;   · 后缀行号平移后 face 仍然正确；
;;;   · CAS 拒绝；
;;;   · split 出来的兄弟 view 共享 doc 级投影基线。

(require rackunit
         racket/string
         (only-in racket/list list-set take drop)
         "../editor/engine/store.rkt"
         "../editor/engine/derived-write.rkt")

(define (join lines) (string-join lines "\n"))

(define (faces-of lines)
  (for/list ([line (in-list lines)])
    (define v (make-vector (string-length line) #f))
    (when (positive? (string-length line))
      (vector-set! v 0 (string->symbol (string-append "face-" line))))
    v))

(define (mk-engine)
  (define e (make-engine))
  (engine-create-buffer! e 10 "*mirror*" "" #:kind 'derived #:owner 'test)
  (engine-create-view! e 10 10)
  e)

(define e (mk-engine))
(define lines0 '("alpha" "beta" "gamma" "delta"))
(define faces0 (faces-of lines0))

(check-true (engine-set-derived-projection! e 10 lines0 faces0))
(check-equal? (engine-view-text e 10) (join lines0))
(check-equal? (engine-view-face-at e 10 1 0) 'face-beta)

;; 同行数改一行：文本和该行 face 更新。
(define lines1 (list-set lines0 1 "BETA"))
(define faces1 (faces-of lines1))
(check-true (engine-set-derived-projection! e 10 lines1 faces1))
(check-equal? (engine-view-text e 10) (join lines1))
(check-equal? (engine-view-face-at e 10 1 0) 'face-BETA)

;; 插入一行：后面的旧行平移，face 跟着平移；新行 face 正确。
(define lines2 (append (take lines1 1) '("inserted") (drop lines1 1)))
(define faces2 (faces-of lines2))
(check-true (engine-set-derived-projection! e 10 lines2 faces2))
(check-equal? (engine-view-text e 10) (join lines2))
(check-equal? (engine-view-face-at e 10 1 0) 'face-inserted)
(check-equal? (engine-view-face-at e 10 2 0) 'face-BETA)
(check-equal? (engine-view-face-at e 10 3 0) 'face-gamma)

;; 删除中间一行：后缀行号回退。
(define lines3 (append (take lines2 2) (drop lines2 3)))
(define faces3 (faces-of lines3))
(check-true (engine-set-derived-projection! e 10 lines3 faces3))
(check-equal? (engine-view-text e 10) (join lines3))
(check-equal? (engine-view-face-at e 10 1 0) 'face-inserted)
(check-equal? (engine-view-face-at e 10 2 0) 'face-gamma)

;; 末尾追加；再删除尾部，不能留下多余空行。
(define lines4 (append lines3 '("tail1" "tail2")))
(define faces4 (faces-of lines4))
(check-true (engine-set-derived-projection! e 10 lines4 faces4))
(check-equal? (engine-view-text e 10) (join lines4))

(define lines5 (take lines4 2))
(define faces5 (faces-of lines5))
(check-true (engine-set-derived-projection! e 10 lines5 faces5))
(check-equal? (engine-view-text e 10) (join lines5))
(check-equal? (length (string-split (engine-view-text e 10) "\n" #:trim? #f))
              (length lines5))

;; face-only：文本不变，只改一行 face。
(define faces6
  (for/list ([v (in-list faces5)] [i (in-naturals)])
    (if (= i 0)
        (let ([v* (vector-copy v)])
          (when (positive? (vector-length v*))
            (vector-set! v* 0 'changed))
          v*)
        v)))
(check-true (engine-set-derived-projection! e 10 lines5 faces6))
(check-equal? (engine-view-face-at e 10 0 0) 'changed)
(check-equal? (engine-view-face-at e 10 1 0) 'face-inserted)

;; CAS：旧版本不能写。
(define wrong-version 'not-current)
(check-false (engine-set-derived-projection! e 10 '("nope") (faces-of '("nope"))
                                             #:base-version wrong-version))
(check-equal? (engine-view-text e 10) (join lines5))

;; split 出来的兄弟 view 共享 doc 级基线。
(define e2 (mk-engine))
(check-true (engine-set-derived-projection! e2 10 lines0 faces0))
(void (engine-create-view-from-view! e2 11 10))
(define lines7 (append lines0 '("extra")))
(define faces7 (faces-of lines7))
(check-true (engine-set-derived-projection! e2 10 lines7 faces7))
(check-equal? (engine-view-text e2 11) (join lines7))
(check-equal? (engine-view-face-at e2 11 4 0) 'face-extra)
;; 从兄弟 view 再写一次，doc 级基线仍然可用。
(define lines8 (take lines7 1))
(define faces8 (faces-of lines8))
(check-true (engine-set-derived-projection! e2 11 lines8 faces8))
(check-equal? (engine-view-text e2 10) (join lines8))

;; 非 derived view 拒绝。
(define u (make-engine))
(void (engine-create-buffer! u 1 "user" "x"))
(void (engine-create-view! u 1 1))
(check-false (engine-set-derived-projection! u 1 '("x") (faces-of '("x"))))

(displayln "edit-tui/test/derived-incremental.rkt: ok")
