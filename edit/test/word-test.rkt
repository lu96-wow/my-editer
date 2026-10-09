#lang racket

;;; edit/test/word-test.rkt —— 词高亮链路验证（headless）
;;;
;;;   raco test edit/test/word-test.rkt
;;;
;;; 覆盖：插件状态（持久词表 → 同词同色、异词异色）/ 活动词跳过（打字中不上色）。

(require rackunit
         racket/file
         "../demo.rkt"
         "../session.rkt"
         "../document/document.rkt"
         "../feature/api.rkt"
         "../core/face.rkt"
         "../core/path.rkt"
         "../plugin/builtin/words.rkt"
         "../../core/editor.rkt"
         "../../core/text/document.rkt")

(define p (make-temporary-file "wd-~a.rkt"))
(display-to-file "alpha beta alpha\nbeta gamma\n" p #:exists 'replace)

(define s (demo-session 80 24))
(define s1 (session-open-file s (normalize p)))
(define did (session-file-did s1 (normalize p)))
(define s2 (session-prepare-render s1))

(define (face-at x row col)
  (document-face-at (editor-document-handle (session-ed x) did) row col))
(define (word-layer f)
  (for/first ([l (in-list (face-layers f))]
              #:when (and (palette-color? l) (eq? 'word (palette-color-kind l))))
    l))
(define (word-idx x row col)
  (define l (word-layer (face-at x row col)))
  (and l (palette-color-index l)))

;; 同词同色 / 异词异色（持久表按首次出现分配）
(check-true (and (word-idx s2 0 0) #t))                    ; "alpha"
(check-equal? (word-idx s2 0 0) (word-idx s2 0 11))        ; 两处 alpha 同号
(check-not-equal? (word-idx s2 0 0) (word-idx s2 0 6))     ; beta 异号

;; 活动词跳过：在词尾打字时该词本次不上色，其余词照常
(define s3 (session-insert s2 "x"))                        ; "xalpha beta alpha"，光标在词中
(define s4 (session-prepare-render s3))
(check-false (word-layer (face-at s4 0 0)))                ; "xalpha" 被跳过
(check-true (and (word-idx s4 0 7) #t))                    ; "beta" 仍上色

;; 敲分隔符让活动词“定下来” → 该词补上色
(define vid (session-edit-vid s2))
(define s5 (session-ed-set-point! s4 vid 0 6))
(define s6 (session-prepare-render (session-insert s5 " ")))
(check-true (and (word-idx s6 0 0) #t))                    ; "xalpha" 现在上色

;; hash 模式经 session 全链路：无状态、同词同色
(define p2 (make-temporary-file "wd-hash-~a.rkt"))
(display-to-file "alpha beta alpha\n" p2 #:exists 'replace)
(define s7 (parameterize ([word-coloring-method 'hash])
             (session-prepare-render (session-open-file s (normalize p2)))))
(define did2 (session-file-did s7 (normalize p2)))
(define (face-at2 row col)
  (document-face-at (editor-document-handle (session-ed s7) did2) row col))
(check-not-false (word-layer (face-at2 0 0)))              ; alpha 有色
(check-equal? (face-at2 0 0) (face-at2 0 11))              ; 两处 alpha 同色

(delete-file p)
(delete-file p2)
