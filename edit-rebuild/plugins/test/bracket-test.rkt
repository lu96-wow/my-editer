#lang racket

;;; edit-rebuild/plugins/test/bracket-test.rkt —— 括号深度背景高亮（headless，插件装配链路）
;;;
;;;   raco test edit-rebuild/plugins/test/bracket-test.rkt
;;;
;;; 覆盖：打开文件 → face 插件绑定 → 渲染前增量写回；嵌套深度取最内层；
;;;       括号背景重画不丢词前景；编辑后增量更新。

(require rackunit
         racket/file
         "../../core/session/adapter.rkt"
         "../../core/session/session.rkt"
         "../../core/session/render.rkt"
         "../../core/session/plugin.rkt"
         "../../core/extension/spec.rkt"
         "../ui/document.rkt"
         "../catalog.rkt"
         "../../core/face/face.rkt"
         "../../core/path.rkt"
         "../../../core/editor.rkt"
         "../../../core/text/document.rkt")

(define p (make-temporary-file "br-~a.rkt"))
(display-to-file "(a [b] c)\n" p #:exists 'replace)

(define s0 (install-plugins (session-blank 80 24) enabled-plugins))
(define s1 (session-set-rules s0 (list (face-plugin-rule (plugin-face-plugins enabled-plugins)))))
(define s2 (session-open-file s1 (normalize p)))
(define did (session-file-did s2 (normalize p)))
(define s3 (session-prepare-render s2))

(define (bg-levels x row col)
  (for/list ([l (in-list (face-layers (document-face-at (editor-document-handle (session-ed x) did) row col)))]
             #:when (palette-bg? l))
    (palette-bg-index l)))

(check-equal? (bg-levels s3 0 0) '(0))       ; "(" 只在外层
(check-equal? (bg-levels s3 0 3) '(1))       ; "[" 最内层
(check-equal? (bg-levels s3 0 4) '(1))       ; "b"
(check-equal? (bg-levels s3 0 8) '(0))       ; ")"

(define (has-word? x row col)
  (for/or ([l (in-list (face-layers (document-face-at (editor-document-handle (session-ed x) did) row col)))])
    (and (palette-color? l) (eq? 'word (palette-color-kind l)))))
(check-true (has-word? s3 0 1))               ; "a"

;; 增量：删掉 "[b]" → 内层消失，外层仍在
(define vid (session-edit-vid s3))
(define s4 (session-ed-replace! s3 vid 0 3 0 6 ""))
(define s5 (session-prepare-render s4))
(check-equal? (session-view-string s5 vid) "(a  c)\n")
(check-equal? (bg-levels s5 0 3) '(0))
(check-not-false (has-word? s5 0 1))

;; 跨行编辑（插入换行）走全量重建路径
(define s6 (session-ed-replace! s5 vid 0 3 0 3 "\n"))
(define s7 (session-prepare-render s6))
(check-equal? (session-view-string s7 vid) "(a \n c)\n")
(check-equal? (bg-levels s7 1 1) '(0))

(delete-file p)
