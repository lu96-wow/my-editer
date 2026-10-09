#lang racket

;;; edit/test/doc-slot-test.rkt —— 插件状态随版本（document 槽）验证（headless）
;;;
;;;   raco test edit/test/doc-slot-test.rkt
;;;
;;; 覆盖：状态存在文档槽、随 fork 携带；undo 恢复旧版本即得旧 state
;;;       （新词号不被已撤销编辑污染）。

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

(define p (make-temporary-file "ds-~a.rkt"))
(display-to-file "alpha beta\n" p #:exists 'replace)

(define s (demo-session 80 24))
(define s1 (session-open-file s (normalize p)))
(define did (session-file-did s1 (normalize p)))

(define (face-at x row col)
  (document-face-at (editor-document-handle (session-ed x) did) row col))
(define (word-idx x row col)
  (for/first ([l (in-list (face-layers (face-at x row col)))]
              #:when (and (palette-color? l) (eq? 'word (palette-color-kind l))))
    (palette-color-index l)))

;; 起始：alpha=0, beta=1
(define s2 (session-prepare-render s1))
(check-equal? (word-idx s2 0 0) 0)
(check-equal? (word-idx s2 0 6) 1)

;; 末尾插入 " gamma " → gamma=2（末尾空格让词“定下来”）
(define vid (session-edit-vid s2))
(define s3 (session-ed-set-point! s2 vid 0 10))
(define s5 (session-prepare-render (session-insert s3 " gamma ")))
(check-equal? (word-idx s5 0 11) 2)

;; undo → 回到 alpha/beta；state 也应回到该版本
(define s6 (session-prepare-render (session-undo s5)))
(check-equal? (session-view-string s6 vid) "alpha beta\n")

;; 再插 " delta "：编号应续在旧 state 后（=2），不被已撤销的 gamma 顶到 3
(define s7 (session-ed-set-point! s6 vid 0 10))
(define s8 (session-prepare-render (session-insert s7 " delta ")))
(check-equal? (session-view-string s8 vid) "alpha beta delta \n")
(check-equal? (word-idx s8 0 11) 2)

(delete-file p)
