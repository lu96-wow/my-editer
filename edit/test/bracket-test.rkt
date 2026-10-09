#lang racket

;;; edit/test/bracket-test.rkt —— 括号深度背景高亮（headless）
;;;
;;;   raco test edit/test/bracket-test.rkt
;;;
;;; 覆盖：嵌套深度取最内层；括号区域重画不丢语法/词前景；编辑后深度增量更新。

(require rackunit
         racket/file
         "../demo.rkt"
         "../session.rkt"
         "../document/document.rkt"
         "../feature/api.rkt"
         "../core/face.rkt"
         "../core/path.rkt"
         "../../core/editor.rkt"
         "../../core/text/document.rkt")

(define p (make-temporary-file "br-~a.rkt"))
(display-to-file "(a [b] c)\n" p #:exists 'replace)

(define s (demo-session 80 24))
(define s1 (session-open-file s (normalize p)))
(define did (session-file-did s1 (normalize p)))
(define s2 (session-prepare-render s1))

;; 该格上括号背景的层（按叠加顺序）。
(define (bg-levels x row col)
  (for/list ([l (in-list (face-layers (document-face-at (editor-document-handle (session-ed x) did) row col)))]
             #:when (palette-bg? l))
    (palette-bg-index l)))

(check-equal? (bg-levels s2 0 0) '(0))       ; "(" 只在外层
(check-equal? (bg-levels s2 0 3) '(0 1))     ; "[" 外层 + 内层（内层最后叠加）
(check-equal? (bg-levels s2 0 4) '(0 1))     ; "b"
(check-equal? (bg-levels s2 0 8) '(0))       ; ")"

;; 括号背景重画后，同行词前景仍在（背景/前景分层）
(define (has-word? x row col)
  (for/or ([l (in-list (face-layers (document-face-at (editor-document-handle (session-ed x) did) row col)))])
    (and (palette-color? l) (eq? 'word (palette-color-kind l)))))
(check-true (has-word? s2 0 1))               ; "a"

;; 增量：删掉 "[b]" → 内层消失，外层仍在
(define vid (session-edit-vid s2))
(define s3 (session-ed-replace! s2 vid 0 3 0 6 ""))
(define s4 (session-prepare-render s3))
(check-equal? (session-view-string s4 vid) "(a  c)\n")
(check-equal? (bg-levels s4 0 3) '(0))       ; 不再有内层
(check-true (has-word? s4 0 1))               ; 词前景不受影响

(delete-file p)
